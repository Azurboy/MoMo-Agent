"""Durability, evidence boundaries and authenticated delivery of life illustrations."""
import base64
import copy
import datetime as dt
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Apps/MacApp/Context'), str(ROOT / 'Apps/MacApp/Runtime'),
                str(ROOT / 'Apps/MacApp/Access'), str(ROOT / 'Vendor/HermesAgent')]
from context_store import ContextStore, digest
from context_server import ContextService
from life_illustrations import LifeIllustrations, evidence_for, visit_evidence, window_at
from life_illustration_generator import CodexIllustrationGenerator, ImageRejected
from rtc_transport import permitted_route

READY = dict(provider='openai-codex', supported=True, service_status='ready')
TEXT = '两个人在桌边讨论新的模块边界，还没有确定最终方案。他们用不同形状的积木摆出数据流，正在尝试重新连接两个模块。'


def png():
    from PIL import Image
    out = io.BytesIO()
    image = Image.new('RGBA', (1024, 1024))
    image.paste((255, 255, 255, 255), (312, 212, 712, 812))
    # Detached semi-transparent ink must survive cropping and thumbnail generation.
    image.paste((30, 29, 27, 128), (292, 192, 300, 200))
    image.paste((30, 29, 27, 1), (1, 1, 5, 5))
    image.save(out, format='PNG')
    return out.getvalue()


class Generator:
    def __init__(self):
        self.prepared, self.generated, self.failure = [], [], None
    def availability(self): return READY
    def prepare(self, evidence):
        self.prepared.append(evidence)
        return '正在讨论，不是完成；桌上有积木。'
    def generate(self, brief, operation, remember):
        self.generated.append(operation); remember('resp_test')
        if self.failure: raise self.failure
        return png()


class IllustrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        self.context = ContextStore(self.data / 'context'); self.addCleanup(self.context.close)
        self.queue = LifeIllustrations(self.data); self.addCleanup(self.queue.close)
        self.start = dt.datetime(2026, 11, 4, 8).timestamp()
        self.payload = dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
                            generation=0, version=1, deleted=False, recorded_at=self.start + 60,
                            spans=[dict(id=str(uuid.uuid4()), recorded_at=self.start + 60, text=TEXT)], text_sha256=digest(TEXT))
        self.context.sync_source(self.payload)
        self.queue.update_settings({'enabled': True}, READY, self.start + 60)
        self.generator = Generator()

    def scan(self):
        self.queue.scan(self.context, self.start + 3 * 3600 + 600)

    def row(self): return self.queue.db.execute('SELECT * FROM slots').fetchone()

    def generate(self):
        self.scan(); self.queue.advance(self.generator, self.context, self.start + 3 * 3600 + 600)

    def test_logical_day_alignment_and_midnight(self):
        window = window_at(dt.datetime(2026, 11, 5, 1).timestamp(), 3, 8)
        self.assertEqual('2026-11-04', window['logical_day'])
        self.assertEqual(dt.datetime(2026, 11, 4, 23).timestamp(), window['window_start'])
        self.assertEqual(dt.datetime(2026, 11, 5, 2).timestamp(), window['window_end'])

    def test_timezone_uses_unambiguous_iana_identifier(self):
        with patch.dict(os.environ, {'TZ': 'Asia/Shanghai'}):
            window = window_at(self.start, 3, 8)
        self.assertEqual('Asia/Shanghai', window['timezone'])

    def test_dst_boundaries_are_local_wall_clock_hours(self):
        from zoneinfo import ZoneInfo
        zone = ZoneInfo('America/New_York')
        timestamp = dt.datetime(2026, 11, 1, 1, 30, tzinfo=zone, fold=1).timestamp()
        with patch.dict(os.environ, {'TZ': 'America/New_York'}):
            window = window_at(timestamp, 3, 8)
        self.assertEqual(dt.datetime(2026, 10, 31, 23, tzinfo=zone).timestamp(), window['window_start'])
        self.assertEqual(dt.datetime(2026, 11, 1, 2, tzinfo=zone).timestamp(), window['window_end'])

    def test_no_history_and_wait_ten_minutes(self):
        old = copy.deepcopy(self.payload); old['session_id'] = str(uuid.uuid4())
        old['spans'][0]['recorded_at'] = self.start - 3600
        self.context.sync_source(old)
        self.queue.scan(self.context, self.start + 3 * 3600 + 599)
        self.assertIsNone(self.row())
        self.scan(); self.assertEqual(1, self.queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])

    def test_pending_empty_source_defers_and_same_revision_can_clear_it(self):
        pending = copy.deepcopy(self.payload); pending['session_id'] = str(uuid.uuid4())
        pending.update(spans=[], text_sha256=digest(''), pending_transcription_ranges=[{'start': self.start + 30, 'end': self.start + 90}])
        self.context.sync_source(pending); self.scan(); self.assertIsNone(self.row())
        pending['pending_transcription_ranges'] = []; self.context.sync_source(pending)
        self.scan(); self.assertEqual('pending', self.row()['state'])
        bad = copy.deepcopy(pending); bad['pending_transcription_ranges'] = [{'start': 2, 'end': 1}]
        with self.assertRaises(ValueError): self.context.sync_source(bad)

    def test_complete_text_summary_and_one_generation_across_restarts(self):
        import recording_summary
        job = recording_summary.enqueue(self.context, dict(library_id=self.payload['library_id'], window_id=f'{int(self.start)}-0',
                                                           revision=digest(TEXT), text=TEXT))
        summary = '完整总结末尾证据：尚未完成。'
        self.context.db.execute("UPDATE recording_summaries SET state='done',result=? WHERE id=?", (summary, job['id']))
        self.generate()
        self.assertEqual(TEXT, self.generator.prepared[0]['passages'][0]['spans'][0]['text'])
        self.assertEqual(summary, self.generator.prepared[0]['passages'][0]['summary'])
        self.assertEqual('ready', self.row()['state'])
        with io.BytesIO(self.queue.asset(self.row()['asset_sha256'])) as buffer:
            from PIL import Image
            self.assertEqual((1024, 1024), Image.open(buffer).size)
        other = LifeIllustrations(self.data)
        try:
            other.recover(); other.scan(self.context, self.start + 5 * 3600); other.advance(self.generator, self.context)
            self.assertEqual(1, len(self.generator.generated))
        finally: other.close()

    def test_rgba_assets_trim_center_and_preserve_complete_ink_bounds(self):
        from PIL import Image
        self.generate()
        row = self.row()
        self.assertEqual((1024, 1024), (row['width'], row['height']))
        for key, side in [('asset_sha256', 1024), ('thumbnail_sha256', 512)]:
            with Image.open(io.BytesIO(self.queue.asset(row[key]))) as image:
                self.assertEqual('RGBA', image.mode)
                self.assertEqual((side, side), image.size)
                alpha = image.getchannel('A')
                self.assertEqual((0, 255), alpha.getextrema())
                left, top, right, bottom = alpha.getbbox()
                self.assertAlmostEqual((left + right) / 2, side / 2, delta=2)
                self.assertAlmostEqual((top + bottom) / 2, side / 2, delta=2)
                self.assertTrue(0.82 * side <= bottom - top <= 0.86 * side)
                self.assertAlmostEqual((right - left) / (bottom - top), 420 / 620, delta=0.02)
                self.assertEqual(0, alpha.getpixel((0, 0)))
                self.assertGreater(sum(alpha.histogram()[100:161]), 0)
                # The upper-left detached stroke stays charcoal, with its original alpha.
                self.assertLess(image.getpixel((left + 2, top + 2))[0], 80)

    def test_empty_alpha_is_rejected_without_publishing(self):
        from PIL import Image
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting'")
        raw = io.BytesIO(); Image.new('RGBA', (1024, 1024)).save(raw, format='PNG')
        with self.assertRaisesRegex(ValueError, 'no visible artwork'):
            self.queue.save_image(self.row()['id'], raw.getvalue())
        self.assertEqual([], self.queue.manifest()['items'])

    def test_opaque_legacy_png_still_fits_without_stretching_or_losing_edges(self):
        from PIL import Image
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting'")
        raw = io.BytesIO(); Image.new('RGB', (1360, 1020), '#fff9ef').save(raw, format='PNG')
        self.queue.save_image(self.row()['id'], raw.getvalue())
        with Image.open(io.BytesIO(self.queue.asset(self.row()['asset_sha256']))) as image:
            self.assertEqual('RGBA', image.mode)
            left, top, right, bottom = image.getchannel('A').getbbox()
            self.assertAlmostEqual((right - left) / (bottom - top), 4 / 3, delta=0.01)

    def test_delete_is_tombstoned_and_does_not_regenerate(self):
        self.generate(); image = self.queue.manifest()['items'][0]
        first = self.queue.manifest()['next_cursor']
        self.queue.delete(image['id']); self.scan(); self.queue.advance(self.generator, self.context)
        page = self.queue.manifest(first)
        self.assertTrue(page['items'][0]['deleted'])
        with self.assertRaises(FileNotFoundError): self.queue.asset(image['asset_sha256'])
        self.assertEqual(1, len(self.generator.generated))
        self.assertEqual('{}', self.row()['evidence'])
        with self.assertRaises(ValueError): self.queue.asset('../state.sqlite')

    def test_punctuation_is_stable_but_corrections_and_source_deletion_withdraw(self):
        self.generate()
        changed = copy.deepcopy(self.payload); changed['version'] += 1
        changed['spans'][0]['text'] = TEXT.replace('。', '！')
        changed['text_sha256'] = digest(changed['spans'][0]['text'])
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])
        changed['version'] += 1; changed['spans'][0]['text'] = '实际上是在公园讨论种植，不是在室内讨论代码。'
        changed['text_sha256'] = digest(changed['spans'][0]['text'])
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('invalid', self.row()['state']); self.assertTrue(self.queue.manifest()['items'][-1]['deleted'])

    def test_later_window_append_does_not_invalidate_first(self):
        self.generate()
        changed = copy.deepcopy(self.payload); changed['version'] += 1
        changed['spans'].append(dict(id=str(uuid.uuid4()), recorded_at=self.start + 4 * 3600, text='下午出门散步。'))
        changed['text_sha256'] = digest('\n'.join(span['text'] for span in changed['spans']))
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])

    def test_deleted_original_withdraws_and_source_ownership_correction_withdraws(self):
        self.generate()
        changed = copy.deepcopy(self.payload); changed['spans'][0]['is_owner'] = False
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('invalid', self.row()['state'])
        changed.update(generation=1, version=0, deleted=True, spans=[], text_sha256=digest(''))
        self.context.sync_source(changed); self.scan()
        self.assertEqual(1, len(self.generator.generated))

    def test_low_value_evidence_skips_and_late_pending_blocks_image_call(self):
        self.scan(); self.generator.prepare = lambda evidence: 'SKIP'
        self.queue.advance(self.generator, self.context)
        self.assertEqual('skipped', self.row()['state']); self.assertEqual([], self.generator.generated)
        self.queue.db.execute("UPDATE slots SET state='pending'")
        changed = copy.deepcopy(self.payload)
        changed['pending_transcription_ranges'] = [{'start': self.start, 'end': self.start + 100}]
        self.context.sync_source(changed)
        self.queue.advance(self.generator, self.context)
        self.assertEqual('pending', self.row()['state']); self.assertEqual([], self.generator.generated)

    def test_delete_during_admission_cannot_revive_or_generate(self):
        self.scan()
        checks = []
        def availability():
            checks.append(True)
            if len(checks) == 2:
                self.queue.delete(self.row()['id'])
            return READY
        self.generator.availability = availability
        self.queue.advance(self.generator, self.context)
        self.assertEqual('deleted', self.row()['state'])
        self.assertEqual([], self.generator.generated)

    def test_delete_while_handling_failed_stream_cannot_revive(self):
        self.scan()
        queue = self.queue
        class RejectedDuringDelete(Exception):
            @property
            def safe_to_retry(self):
                queue.delete(queue.db.execute('SELECT id FROM slots').fetchone()['id'])
                return True
        self.generator.failure = RejectedDuringDelete()
        self.queue.advance(self.generator, self.context)
        self.assertEqual('deleted', self.row()['state'])
        self.assertEqual('{}', self.row()['evidence'])

    def test_crash_before_image_result_and_bad_pixels_never_become_ready(self):
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting',request_id='persistent'")
        self.queue.recover(); self.assertEqual('needs_review', self.row()['state'])
        self.queue.db.execute("UPDATE slots SET state='submitting'")
        with self.assertRaises(Exception): self.queue.save_image(self.row()['id'], b'not a PNG')
        self.assertEqual([], self.queue.manifest()['items'])

    def test_unknown_image_outcome_never_replays_and_spooled_image_recovers(self):
        self.generator.failure = TimeoutError()
        self.generate()
        self.assertEqual('needs_review', self.row()['state'])
        self.queue.recover(); self.queue.advance(self.generator, self.context)
        self.assertEqual(1, len(self.generator.generated))
        self.queue.db.execute("UPDATE slots SET state='submitting'")
        spool = self.queue.directory / (self.row()['id'] + '.result.png'); spool.write_bytes(png())
        self.queue.recover(); self.assertEqual('ready', self.row()['state']); self.assertFalse(spool.exists())

    def test_rejected_admission_has_bounded_retries(self):
        self.generator.failure = ImageRejected()
        self.generate()
        self.assertEqual('pending', self.row()['state'])
        for attempt in range(2):
            self.queue.advance(self.generator, self.context, self.start + 10 * 3600 + attempt * 1000)
        self.assertEqual('failed', self.row()['state']); self.assertEqual(3, len(self.generator.generated))
        self.assertEqual(1, len(set(self.generator.generated)))

    def test_unsupported_provider_does_not_call_models(self):
        self.scan(); self.generator.availability = lambda: dict(supported=False)
        self.queue.advance(self.generator, self.context)
        self.assertEqual([], self.generator.prepared); self.assertEqual([], self.generator.generated)

    def test_visits_require_closed_overlap_actual_provenance_and_accuracy(self):
        visits = [dict(id='valid', source_name='CoreLocation visits', start=self.start, end=self.start + 3600,
                       title='河边', latitude=31, longitude=121, accuracy=20),
                  dict(id='future', source_name='CoreLocation visits', start=self.start + 4*3600, end=self.start + 5*3600,
                       title='京都', latitude=31, longitude=121, accuracy=20)]
        visits += [dict(visits[0], id='open', end=None), dict(visits[0], id='gps', source_name='current GPS'),
                   dict(visits[0], id='vague', accuracy=201), dict(visits[0], id='short', end=self.start + 299),
                   dict(visits[0], id='boundary', start=self.start + 4000, end=self.start + 4300, accuracy=200)]
        self.context.db.execute('INSERT INTO phone_source_snapshots VALUES(?,?,?,?,?)',
                               (self.payload['device_id'], 'visits', 1, json.dumps(dict(state='enabled', records=visits)), self.start))
        result = visit_evidence(self.context, self.start, self.start + 3*3600)
        self.assertEqual(['valid', 'boundary'], [visit['id'] for visit in result])

    def test_visit_becoming_unreliable_withdraws_existing_picture(self):
        visit = dict(id='visit', source_name='CoreLocation visits', start=self.start, end=self.start + 3600,
                     title='河边', latitude=31, longitude=121, accuracy=20)
        snapshot = dict(state='enabled', records=[visit], window_start=self.start, window_end=self.start + 3*3600)
        self.context.db.execute('INSERT INTO phone_source_snapshots VALUES(?,?,?,?,?)',
                               (self.payload['device_id'], 'visits', 1, json.dumps(snapshot), self.start))
        self.generate(); self.assertEqual('河边', self.row()['place'])
        visit['accuracy'] = 900
        self.context.db.execute("UPDATE phone_source_snapshots SET revision=2,payload=? WHERE kind='visits'", (json.dumps(snapshot),))
        self.queue.reconcile(self.context)
        self.assertEqual('invalid', self.row()['state'])

    def test_incremental_manifest_paginates_without_losing_tombstones(self):
        self.generate(); self.queue.delete(self.row()['id'])
        first = self.queue.manifest(limit=1); self.assertTrue(first['has_more'])
        self.assertTrue(first['items'][0]['deleted'])  # The old ready event no longer references pruned pixels.
        second = self.queue.manifest(first['next_cursor'], 1)
        self.assertTrue(second['items'][0]['deleted']); self.assertFalse(second['has_more'])

    def test_access_route_allowlist(self):
        base = '/context/v1/life-illustrations/'
        for method, path in [('GET', 'settings'), ('POST', 'settings'), ('GET', 'manifest?cursor=0&limit=10'),
                             ('GET', 'assets/' + 'a'*64), ('POST', 'delete')]:
            self.assertIsNotNone(permitted_route(method, base + path))
        for path in ['assets/../state.sqlite', 'manifest?url=https://evil.test', 'settings?admin=1']:
            self.assertIsNone(permitted_route('GET', base + path))

    def test_authenticated_settings_manifest_and_binary_asset(self):
        self.generate(); sha = self.row()['asset_sha256']
        (self.data/'api-key').write_text('test-key')
        service = ContextService(self.data, dict(data_url='http://127.0.0.1:0', workspace_id='test'))
        thread = threading.Thread(target=service.server.serve_forever, daemon=True); thread.start()
        base = f'http://127.0.0.1:{service.server.server_port}/v1/life-illustrations/'
        try:
            with self.assertRaises(urllib.error.HTTPError) as denied: urllib.request.urlopen(base+'settings')
            self.assertEqual(401, denied.exception.code)
            with patch.object(CodexIllustrationGenerator, 'availability', return_value=READY):
                request = urllib.request.Request(base+'assets/'+sha, headers={'Authorization': 'Bearer test-key'})
                with urllib.request.urlopen(request) as response:
                    self.assertEqual('image/png', response.headers['Content-Type'])
                    self.assertEqual(self.queue.asset(sha), response.read())
                request = urllib.request.Request(base+'settings', headers={'Authorization': 'Bearer test-key', 'Content-Type': 'application/json'},
                                                 data=b'{"interval_hours":4}')
                with urllib.request.urlopen(request) as response:
                    self.assertEqual(4, json.load(response)['interval_hours'])
        finally:
            service.server.shutdown(); service.server.server_close(); thread.join()


class NativeImageStreamTests(unittest.TestCase):
    def test_ig_item_result_and_native_subscription_request(self):
        image = png()
        events = [SimpleNamespace(type='response.created', response=SimpleNamespace(id='resp_123')),
                  SimpleNamespace(type='response.output_item.done', item=SimpleNamespace(type='image_generation_call', id='ig_123', result=base64.b64encode(image).decode()))]
        class Stream:
            def __enter__(self): return iter(events)
            def __exit__(self, *args): pass
        class Client:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            @property
            def responses(self): return self
            def create(self, **kwargs): self.kwargs = kwargs; return Stream()
        generator, client = CodexIllustrationGenerator(Path('/unused')), Client()
        generator.resolve = lambda: dict(model_id='configured-codex-model')
        generator.client = lambda llm: client
        ids = []
        self.assertEqual(image, generator.generate('真实场景', 'operation', ids.append))
        self.assertEqual(['resp_123'], ids)
        self.assertEqual(False, client.kwargs['store']); self.assertEqual(True, client.kwargs['stream'])
        self.assertEqual('1024x1024', client.kwargs['tools'][0]['size'])
        self.assertEqual('medium', client.kwargs['tools'][0]['quality'])
        self.assertEqual('transparent', client.kwargs['tools'][0]['background'])
        self.assertEqual('png', client.kwargs['tools'][0]['output_format'])
        content = client.kwargs['input'][0]['content']
        self.assertEqual('input_image', content[0]['type'])
        self.assertTrue(content[0]['image_url'].startswith('data:image/png;base64,'))
        self.assertEqual((ROOT / 'Apps/MacApp/Runtime/momo_character_reference.png').read_bytes(),
                         base64.b64decode(content[0]['image_url'].split(',', 1)[1]))
        self.assertEqual({'type': 'input_text', 'text': '真实场景'}, content[1])
        self.assertEqual({'X-Client-Request-Id': 'operation'}, client.kwargs['extra_headers'])


if __name__ == '__main__': unittest.main()
