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
from life_illustrations import LifeIllustrations, evidence_for, is_dense_conversation, visit_evidence, trajectory_evidence, window_at
from life_illustration_generator import CodexIllustrationGenerator, ImageRejected, parse_scene_output
from rtc_transport import permitted_route

READY = dict(provider='openai-codex', supported=True, service_status='ready')
TEXT = (
    '两个人在桌边讨论新的模块边界，还没有确定最终方案。'
    '他们用不同形状的积木摆出数据流，正在尝试重新连接两个模块，'
    '并逐一核对接口字段与超时重试逻辑，看看高并发下哪里还会出现阻塞，最后决定先写一版最小原型验证。'
)


def png():
    from PIL import Image
    out = io.BytesIO()
    image = Image.new('RGBA', (1024, 1024))
    image.paste((255, 255, 255, 255), (312, 212, 712, 812))
    # Semi-transparent ink survives while near-invisible stray alpha is removed.
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

    def test_never_generated_history_resumes_without_waiting_for_new_recordings(self):
        old = copy.deepcopy(self.payload); old['session_id'] = str(uuid.uuid4())
        old['spans'][0]['recorded_at'] = self.start - 3600
        self.context.sync_source(old)
        self.queue.scan(self.context, self.start + 60 + min(60, len(TEXT) * 0.22) + 599)
        self.assertEqual(1, self.queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])
        self.assertEqual(self.start - 3600, self.row()['window_start'])
        self.scan(); self.assertEqual(2, self.queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])
        self.queue.advance(self.generator, self.context)
        self.assertEqual(self.start + 60, self.generator.prepared[0]['passages'][0]['spans'][0]['recorded_at'])

    def test_historical_backfill_preserves_completed_deleted_and_unknown_attempts(self):
        self.generate()
        identity = self.row()['id']
        for state in ['ready', 'invalid', 'deleted', 'needs_review']:
            with self.subTest(state=state):
                self.queue.db.execute('UPDATE slots SET state=? WHERE id=?', (state, identity))
                self.scan(); self.queue.advance(self.generator, self.context)
                self.assertEqual(state, self.row()['state'])
                self.assertEqual(1, self.queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])
                self.assertEqual(1, len(self.generator.generated))
        self.queue.update_settings({'enabled': False}, READY)
        old = copy.deepcopy(self.payload); old['session_id'] = str(uuid.uuid4())
        old['spans'][0]['recorded_at'] = self.start - 86400
        self.context.sync_source(old); self.scan()
        self.assertEqual(1, self.queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])

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

    def test_transparent_png_builds_kiss_cut_sticker_with_transparent_corners(self):
        from PIL import Image, ImageDraw
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting'")
        artwork = Image.new('RGBA', (1024, 1024))
        ImageDraw.Draw(artwork).ellipse((350, 350, 674, 674), fill='#161514')
        artwork.putpixel((2, 2), (0, 0, 0, 10))
        raw = io.BytesIO(); artwork.save(raw, format='PNG')
        self.queue.save_image(self.row()['id'], raw.getvalue())
        for key, side in [('asset_sha256', 1024), ('thumbnail_sha256', 512)]:
            with Image.open(io.BytesIO(self.queue.asset(self.row()[key]))) as image:
                self.assertEqual('RGBA', image.mode)
                self.assertEqual((side, side), image.size)
                for point in [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)]:
                    self.assertEqual(0, image.getpixel(point)[3])
                self.assertEqual((22, 21, 20, 255), image.getpixel((side // 2, side // 2)))
                self.assertIn((250, 248, 242, 255), image.getdata())
                alpha = image.getchannel('A')
                self.assertTrue(any(0 < value < 255 for value in alpha.getdata()))
                bounds = alpha.getbbox()
                if side == 512:
                    self.assertGreaterEqual(max(bounds[2] - bounds[0], bounds[3] - bounds[1]), 464)
                    self.assertLessEqual(max(bounds[2] - bounds[0], bounds[3] - bounds[1]), 468)
                else:
                    self.assertLess(max(bounds[2] - bounds[0], bounds[3] - bounds[1]), 800)

    def test_transparent_processing_is_deterministic(self):
        from PIL import Image
        from life_illustration_sticker import kiss_cut_sticker
        artwork = Image.open(io.BytesIO(png()))
        first = kiss_cut_sticker(artwork)
        second = kiss_cut_sticker(artwork)
        self.assertEqual([image.tobytes() for image in first], [image.tobytes() for image in second])

    def test_editorial_rgb_preserves_negative_space_and_full_bleed_ground(self):
        from PIL import Image
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting'")
        artwork = Image.new('RGB', (1024, 1024), '#B8C9C3')
        artwork.paste('#FAF9F5', (520, 650, 750, 850))
        artwork.paste('#161514', (600, 720, 610, 740))
        raw = io.BytesIO(); artwork.save(raw, format='PNG')
        self.queue.save_image(self.row()['id'], raw.getvalue())
        for key, side in [('asset_sha256', 1024), ('thumbnail_sha256', 512)]:
            with Image.open(io.BytesIO(self.queue.asset(self.row()[key]))) as image:
                self.assertEqual('RGB', image.mode)
                self.assertEqual(artwork.resize((side, side), Image.Resampling.LANCZOS).tobytes(), image.tobytes())
                self.assertEqual((184, 201, 195), image.getpixel((0, 0)))

    def test_empty_alpha_is_rejected_without_publishing(self):
        from PIL import Image
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting'")
        raw = io.BytesIO(); Image.new('RGBA', (1024, 1024)).save(raw, format='PNG')
        with self.assertRaisesRegex(ValueError, 'no visible artwork'):
            self.queue.save_image(self.row()['id'], raw.getvalue())
        self.assertEqual([], self.queue.manifest()['items'])

    def test_non_square_png_uses_center_fit_without_stretching(self):
        from PIL import Image, ImageOps
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting'")
        artwork = Image.new('RGB', (1360, 1020), '#EAE5DB')
        artwork.paste('#161514', (500, 400, 800, 700))
        raw = io.BytesIO(); artwork.save(raw, format='PNG')
        self.queue.save_image(self.row()['id'], raw.getvalue())
        with Image.open(io.BytesIO(self.queue.asset(self.row()['asset_sha256']))) as image:
            expected = ImageOps.fit(artwork, (1024, 1024), method=Image.Resampling.LANCZOS)
            self.assertEqual(expected.tobytes(), image.tobytes())

    def test_solid_blank_images_are_rejected_without_publishing(self):
        from PIL import Image
        self.scan(); self.queue.db.execute("UPDATE slots SET state='submitting'")
        for mode in ('RGB', 'RGBA', 'P'):
            with self.subTest(mode=mode):
                raw = io.BytesIO(); Image.new('RGB', (1024, 1024), '#B8C9C3').convert(mode, dither=Image.Dither.NONE).save(raw, format='PNG')
                with self.assertRaisesRegex(ValueError, 'no visible variation'):
                    self.queue.save_image(self.row()['id'], raw.getvalue())
                self.assertEqual([], self.queue.manifest()['items'])

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

    def test_saved_artifact_survives_punctuation_content_and_owner_updates(self):
        self.generate()
        changed = copy.deepcopy(self.payload); changed['version'] += 1
        changed['spans'][0]['text'] = TEXT.replace('。', '！')
        changed['text_sha256'] = digest(changed['spans'][0]['text'])
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])
        changed['version'] += 1
        changed['spans'][0]['text'] = (
            '两个人在公园长椅旁讨论阳台种植计划，还没有确定最终土壤配比。'
            '他们翻看笔记本里的日照记录，正在对比几种耐阴植物在秋季的浇水频率与通风条件。'
        )
        changed['text_sha256'] = digest(changed['spans'][0]['text'])
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])
        self.assertFalse(self.queue.manifest()['items'][-1]['deleted'])
        self.assertTrue(self.queue.asset(self.row()['asset_sha256']))
        changed['spans'][0]['is_owner'] = False
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])
        self.scan(); self.queue.advance(self.generator, self.context)
        self.assertEqual(1, len(self.generator.generated))

    def test_later_window_append_does_not_invalidate_first(self):
        self.generate()
        changed = copy.deepcopy(self.payload); changed['version'] += 1
        changed['spans'].append(dict(id=str(uuid.uuid4()), recorded_at=self.start + 4 * 3600, text='下午出门散步。'))
        changed['text_sha256'] = digest('\n'.join(span['text'] for span in changed['spans']))
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])

    def test_explicit_source_deletion_removes_artifact_but_owner_correction_preserves_it(self):
        self.generate()
        changed = copy.deepcopy(self.payload); changed['spans'][0]['is_owner'] = False
        self.context.sync_source(changed); self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])
        changed.update(generation=1, version=0, deleted=True, spans=[], text_sha256=digest(''))
        self.context.sync_source(changed); self.scan()
        self.assertEqual(1, len(self.generator.generated))
        self.assertEqual('deleted', self.row()['state'])
        self.assertFalse(list(self.queue.assets.glob('*.png')))

    def test_preparing_refreshes_evidence_without_becoming_permanently_invalid(self):
        self.scan()
        changed = copy.deepcopy(self.payload)
        changed['spans'][0]['is_owner'] = True
        self.context.sync_source(changed)
        self.queue.reconcile(self.context)
        self.assertEqual('pending', self.row()['state'])
        self.queue.advance(self.generator, self.context)
        self.assertEqual('ready', self.row()['state'])
        self.assertTrue(self.generator.prepared[0]['passages'][0]['spans'][0]['is_owner'])
        self.assertEqual(1, len(self.generator.generated))

    def test_source_refresh_during_accepted_image_request_preserves_result(self):
        generate = self.generator.generate
        def refresh_then_generate(*args):
            changed = copy.deepcopy(self.payload)
            changed['spans'][0]['is_owner'] = False
            self.context.sync_source(changed)
            self.queue.reconcile(self.context)
            self.assertEqual('submitting', self.row()['state'])
            return generate(*args)
        self.generator.generate = refresh_then_generate
        self.generate()
        self.assertEqual('ready', self.row()['state'])
        self.assertTrue(self.queue.asset(self.row()['asset_sha256']))
        self.scan(); self.queue.advance(self.generator, self.context)
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

    def test_visits_match_recording_time_actual_provenance_and_accuracy(self):
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
        self.assertEqual(['valid', 'boundary', 'short'], [visit['id'] for visit in result])

    def test_ongoing_visit_locates_recording_without_waiting_for_departure(self):
        snapshot = self.install_journey()
        snapshot['records'][0]['end'] = None
        self.context.db.execute('UPDATE phone_source_snapshots SET payload=?', (json.dumps(snapshot),))
        self.generate()
        self.assertEqual(('工作室', 39.9982, 116.4796),
            (self.row()['place'], self.row()['latitude'], self.row()['longitude']))
        self.assertIsNone(self.row()['place_start'])
        self.assertIsNone(self.row()['place_end'])

    def test_ongoing_visit_stops_at_next_arrival_and_snapshot_observation(self):
        records = [dict(id='old', source_name='CoreLocation visits', start=self.start, end=None,
                        latitude=31, longitude=121, accuracy=20),
                   dict(id='next', source_name='CoreLocation visits', start=self.start + 600, end=None,
                        latitude=32, longitude=122, accuracy=20)]
        snapshot = dict(state='enabled', records=records, observed_at=self.start + 1200)
        self.context.db.execute('INSERT INTO phone_source_snapshots VALUES(?,?,?,?,?)',
            (self.payload['device_id'], 'visits', 1, json.dumps(snapshot), self.start))
        self.assertEqual(['next'], [point['id'] for point in visit_evidence(self.context, self.start + 700, self.start + 800)])
        self.assertEqual([], visit_evidence(self.context, self.start + 1300, self.start + 1400))

    def install_journey(self):
        records = [dict(id='stay', source_name='CoreLocation visits', start=self.start, end=self.start + 3600,
                        title='工作室', latitude=39.9982, longitude=116.4796, accuracy=20),
                   dict(id='transit', source_name='CoreLocation significant_change', start=self.start + 4000,
                        end=self.start + 4000, latitude=39.9685, longitude=116.4660, accuracy=80)]
        snapshot = dict(state='enabled', window_start=self.start, window_end=self.start + 10800, records=records)
        self.context.db.execute('INSERT INTO phone_source_snapshots VALUES(?,?,?,?,?)',
            (self.payload['device_id'], 'visits', 1, json.dumps(snapshot), self.start))
        return snapshot

    def test_scene_output_legacy_structured_json_and_skip(self):
        self.assertEqual((None, 'SKIP'), parse_scene_output(' SKIP '))
        self.assertEqual(('喝茶看书', '喝茶看书'), parse_scene_output('喝茶看书'))
        self.assertEqual(('一起讨论模块边界', '桌边有两组积木。方案还没确定。'),
            parse_scene_output('SUMMARY: 一起讨论模块边界\nBRIEF: 桌边有两组积木。方案还没确定。'))
        self.assertEqual(('喝茶', '手里拿着茶杯'), parse_scene_output('{"summary":"喝茶","brief":"手里拿着茶杯"}'))
        self.assertEqual(56, len(parse_scene_output('字' * 120)[0]))

    def test_summary_and_trajectory_publish_without_private_provenance(self):
        self.install_journey()
        self.generator.prepare = lambda evidence: 'SUMMARY: 在工作室用积木讨论模块交接，方案还没确定\nBRIEF: 两人在桌边用积木说明模块边界。'
        self.generate()
        item = self.queue.manifest()['items'][0]
        self.assertEqual('在工作室用积木讨论模块交接，方案还没确定', item['summary'])
        self.assertEqual(('工作室', 39.9982, 116.4796), (item['place'], item['latitude'], item['longitude']))
        self.assertEqual(self.start, item['place_start'])
        self.assertEqual(['visit'], [point['kind'] for point in item['route_points']])
        self.assertNotIn('device_id', item['route_points'][0])
        self.assertEqual(1, len(json.loads(self.row()['evidence'])['trajectory']))

    def test_transit_alone_never_attributes_a_stay(self):
        snapshot = self.install_journey()
        snapshot['records'] = snapshot['records'][1:]
        self.context.db.execute('UPDATE phone_source_snapshots SET payload=?', (json.dumps(snapshot),))
        self.generate()
        self.assertIsNone(self.row()['place'])
        self.assertIsNone(self.row()['latitude'])
        self.assertEqual([], json.loads(self.row()['route_points']))

    def test_saved_artifact_survives_location_snapshot_refresh_and_permission_changes(self):
        snapshot = self.install_journey()
        self.generate()
        before = dict(self.row())
        image = self.queue.asset(before['asset_sha256'])
        for revision, state in [(2, 'enabled'), (3, 'needs_permission')]:
            snapshot.update(state=state, records=[], window_start=self.start + 20000, window_end=self.start + 30000)
            self.context.db.execute("UPDATE phone_source_snapshots SET revision=?,payload=?", (revision, json.dumps(snapshot)))
            self.queue.reconcile(self.context)
            self.assertEqual('ready', self.row()['state'])
            self.assertEqual(before['summary'], self.row()['summary'])
            self.assertEqual(before['route_points'], self.row()['route_points'])
            self.assertEqual(image, self.queue.asset(before['asset_sha256']))
        self.assertTrue(all(not item['deleted'] for item in self.queue.manifest()['items']))

    def test_late_ongoing_visit_enriches_saved_sticker_without_regeneration(self):
        self.generate()
        before = dict(self.row())
        self.assertIsNone(before['latitude'])
        pixels = self.queue.asset(before['asset_sha256'])
        first_manifest = self.queue.manifest()
        snapshot = self.install_journey()
        snapshot['records'][0]['end'] = None
        self.context.db.execute('UPDATE phone_source_snapshots SET revision=2,payload=?', (json.dumps(snapshot),))
        self.queue.reconcile(self.context)
        after = dict(self.row())
        self.assertEqual(('工作室', 39.9982, 116.4796), (after['place'], after['latitude'], after['longitude']))
        for field in ('id', 'state', 'asset_sha256', 'thumbnail_sha256', 'summary', 'brief', 'request_id', 'attempt'):
            self.assertEqual(before[field], after[field], field)
        self.assertEqual(pixels, self.queue.asset(after['asset_sha256']))
        self.assertEqual(1, len(self.generator.generated))
        updates = self.queue.manifest(first_manifest['next_cursor'])
        self.assertEqual(1, len(updates['items']))
        self.assertFalse(updates['items'][0]['deleted'])
        self.assertEqual('工作室', updates['items'][0]['place'])
        self.context.db.execute('UPDATE phone_source_snapshots SET revision=3')
        self.queue.reconcile(self.context)
        self.assertEqual([], self.queue.manifest(updates['next_cursor'])['items'])

    def test_recorded_fix_enriches_saved_map_without_inventing_stay_times(self):
        self.generate()
        before = dict(self.row())
        snapshot = self.install_journey()
        snapshot['records'] = [dict(snapshot['records'][1], start=self.start + 80, end=self.start + 80)]
        self.context.db.execute('UPDATE phone_source_snapshots SET payload=?', (json.dumps(snapshot),))
        # Explicit GMT zones are also valid server output on machines without a named local zone.
        self.queue.db.execute("UPDATE slots SET timezone='GMT+08:00'")
        self.queue.reconcile(self.context)
        after = dict(self.row())
        self.assertEqual((39.9685, 116.4660), (after['latitude'], after['longitude']))
        self.assertIsNone(after['place_start'])
        self.assertIsNone(after['place_end'])
        self.assertEqual(before['route_points'], after['route_points'])
        self.assertEqual(before['asset_sha256'], after['asset_sha256'])
        self.assertEqual(1, len(self.generator.generated))

    def test_bounded_trajectory_keeps_stays_and_rejects_nonfinite_coordinates(self):
        snapshot = self.install_journey()
        waypoint = snapshot['records'][1]
        snapshot['records'] += [dict(waypoint, id=f'p-{index}', start=self.start + 4001 + index,
                                    end=self.start + 4001 + index) for index in range(100)]
        snapshot['records'] += [dict(waypoint, id='bad', latitude=float('nan'))]
        self.context.db.execute('UPDATE phone_source_snapshots SET payload=?', (json.dumps(snapshot),))
        points = trajectory_evidence(self.context, self.start, self.start + 10800)
        self.assertEqual(64, len(points))
        self.assertEqual('stay', points[0]['id'])
        self.assertEqual('p-99', points[-1]['id'])
        self.assertNotIn('bad', [point['id'] for point in points])

    def test_schema_migration_is_idempotent_for_legacy_slots(self):
        self.scan()
        for name in ('summary', 'latitude', 'longitude', 'place_start', 'place_end', 'route_points'):
            self.queue.db.execute(f'ALTER TABLE slots DROP COLUMN {name}')
        self.queue.ensure_columns()
        self.queue.ensure_columns()
        self.generate()
        self.assertEqual('ready', self.row()['state'])

    def test_visit_becoming_unreliable_preserves_saved_picture(self):
        visit = dict(id='visit', source_name='CoreLocation visits', start=self.start, end=self.start + 3600,
                     title='河边', latitude=31, longitude=121, accuracy=20)
        snapshot = dict(state='enabled', records=[visit], window_start=self.start, window_end=self.start + 3*3600)
        self.context.db.execute('INSERT INTO phone_source_snapshots VALUES(?,?,?,?,?)',
                               (self.payload['device_id'], 'visits', 1, json.dumps(snapshot), self.start))
        self.generate(); self.assertEqual('河边', self.row()['place'])
        visit['accuracy'] = 900
        self.context.db.execute("UPDATE phone_source_snapshots SET revision=2,payload=? WHERE kind='visits'", (json.dumps(snapshot),))
        self.queue.reconcile(self.context)
        self.assertEqual('ready', self.row()['state'])
        self.assertTrue(self.queue.asset(self.row()['asset_sha256']))

    def test_incremental_manifest_paginates_without_losing_tombstones(self):
        self.generate(); self.queue.delete(self.row()['id'])
        first = self.queue.manifest(limit=1); self.assertTrue(first['has_more'])
        self.assertTrue(first['items'][0]['deleted'])  # The old ready event no longer references pruned pixels.
        second = self.queue.manifest(first['next_cursor'], 1)
        self.assertTrue(second['items'][0]['deleted']); self.assertFalse(second['has_more'])

    def test_short_remarks_and_filler_words_are_excluded(self):
        short_text = '今天中午吃什么？去楼下吃碗牛肉面吧，顺便买杯咖啡。'
        filler_text = '嗯，啊，好的好的，对对对，哈哈哈哈，那个，就是说，行吧，没问题，OK，明白明白！' * 6
        self.assertFalse(is_dense_conversation(short_text))
        self.assertFalse(is_dense_conversation(filler_text))
        self.assertTrue(is_dense_conversation(TEXT))
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        data = Path(tmp.name)
        ctx = ContextStore(data / 'context'); self.addCleanup(ctx.close)
        queue = LifeIllustrations(data); self.addCleanup(queue.close)
        queue.update_settings({'enabled': True}, READY, self.start)
        spans = [
            dict(id=str(uuid.uuid4()), recorded_at=self.start + 120, text=short_text),
            dict(id=str(uuid.uuid4()), recorded_at=self.start + 1200, text=filler_text),
        ]
        body = '\n'.join(s['text'] for s in spans)
        ctx.sync_source(dict(
            library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
            generation=0, version=1, deleted=False, recorded_at=self.start + 120,
            spans=spans, text_sha256=digest(body),
        ))
        queue.scan(ctx, self.start + 4 * 3600)
        self.assertEqual(0, queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])

    def test_finished_conversations_are_admitted_before_batch_boundary(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        data = Path(tmp.name)
        ctx = ContextStore(data / 'context'); self.addCleanup(ctx.close)
        queue = LifeIllustrations(data); self.addCleanup(queue.close)
        queue.update_settings({'enabled': True, 'interval_hours': 3}, READY, self.start)
        # 10 distinct dense conversations across one logical day (3 inside the first 08:00-11:00 batch alone)
        offsets = [600, 2400, 4800, 11400, 14400, 22200, 25200, 33000, 36600, 45000]
        spans = [
            dict(id=str(uuid.uuid4()), recorded_at=self.start + offset, text=f'第{idx + 1}场讨论：{TEXT}')
            for idx, offset in enumerate(offsets)
        ]
        body = '\n'.join(s['text'] for s in spans)
        ctx.sync_source(dict(
            library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
            generation=0, version=1, deleted=False, recorded_at=self.start + 600,
            spans=spans, text_sha256=digest(body),
        ))
        # All three morning conversations are ready after their own quiet period, before the 11:00 checkpoint.
        queue.scan(ctx, self.start + 2 * 3600)
        self.assertEqual(3, queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])
        # After all batches of the day settle, all 10 dense conversations (> 24/3 = 8) become individual illustrations.
        now = self.start + 16 * 3600
        queue.scan(ctx, now)
        self.assertEqual(10, queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])
        while queue.advance(self.generator, ctx, now):
            pass
        items = [item for item in queue.manifest()['items'] if not item['deleted']]
        self.assertEqual(10, len(items))
        self.assertEqual([self.start + offset for offset in offsets], sorted(item['window_start'] for item in items))

    def test_conversation_crossing_batch_boundary_stays_uncut(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        data = Path(tmp.name)
        ctx = ContextStore(data / 'context'); self.addCleanup(ctx.close)
        queue = LifeIllustrations(data); self.addCleanup(queue.close)
        queue.update_settings({'enabled': True, 'interval_hours': 3}, READY, self.start)
        # Conversation runs across 11:00 (10:54 -> 11:02 -> 11:09 -> 11:16) with <10min gaps
        times = [3 * 3600 - 360, 3 * 3600 + 120, 3 * 3600 + 540, 3 * 3600 + 960]
        spans = [dict(id=str(uuid.uuid4()), recorded_at=self.start + t, text=TEXT) for t in times]
        body = '\n'.join(s['text'] for s in spans)
        ctx.sync_source(dict(
            library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
            generation=0, version=1, deleted=False, recorded_at=self.start + times[0],
            spans=spans, text_sha256=digest(body),
        ))
        # At 11:10 (first batch settle), the ongoing conversation is NOT cut at 11:00.
        queue.scan(ctx, self.start + 3 * 3600 + 600)
        self.assertEqual(0, queue.db.execute('SELECT COUNT(*) FROM slots').fetchone()[0])
        # Ten minutes after the last speech ends, the whole conversation is eligible without waiting until 14:10.
        queue.scan(ctx, self.start + times[-1] + min(60, len(TEXT) * 0.22) + 600)
        rows = queue.db.execute('SELECT * FROM slots').fetchall()
        self.assertEqual(1, len(rows))
        self.assertEqual(self.start + times[0], rows[0]['window_start'])
        self.assertGreater(rows[0]['window_end'], self.start + times[-1])

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
            # Reading a saved image requires device authentication, not an active image-generation subscription.
            with patch.object(CodexIllustrationGenerator, 'availability', return_value=dict(
                    provider='anthropic', supported=False, service_status='unsupported_provider')):
                for suffix in ('manifest', 'assets/' + sha):
                    request = urllib.request.Request(base + suffix, headers={'Authorization': 'Bearer test-key'})
                    with urllib.request.urlopen(request) as response:
                        if suffix == 'manifest':
                            self.assertFalse(json.load(response)['items'][0]['deleted'])
                        else:
                            self.assertEqual(self.queue.asset(sha), response.read())
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
        from PIL import Image
        with Image.open(io.BytesIO(base64.b64decode(content[0]['image_url'].split(',', 1)[1]))) as reference:
            self.assertEqual((768, 768), reference.size)
        self.assertEqual({'type': 'input_text', 'text': '真实场景'}, content[1])
        self.assertEqual({'X-Client-Request-Id': 'operation'}, client.kwargs['extra_headers'])

    def test_availability_recognizes_logged_in_codex_and_separates_transient_errors(self):
        with tempfile.TemporaryDirectory() as raw:
            data = Path(raw)
            (data / 'hermes').mkdir(parents=True)
            (data / 'hermes/auth.json').write_text(json.dumps({'active_provider': 'openai-codex'}), encoding='utf-8')
            generator = CodexIllustrationGenerator(data)
            with patch('model_setup.resolve_credentials', return_value={'api_key': 'tok', 'base_url': 'https://chatgpt.com/backend-api'}), \
                 patch('model_setup.catalog', return_value=['gpt-5.4']):
                self.assertEqual({'provider': 'openai-codex', 'supported': True, 'service_status': 'ready'}, generator.availability())
            with patch.object(generator, 'resolve', side_effect=RuntimeError('sqlite busy')):
                self.assertEqual({'provider': 'openai-codex', 'supported': False, 'service_status': 'unavailable'}, generator.availability())


if __name__ == '__main__': unittest.main()
