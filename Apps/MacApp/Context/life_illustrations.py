"""One durable, opt-in life-illustration queue. Views only read finished assets."""
from contextlib import contextmanager
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import time
import unicodedata
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from context_store import canonical, digest, read_day_start_hour

INTERVALS = (2, 3, 4, 6)
SETTLE_SECONDS = 600
MAX_ASSET_BYTES = 8 * 1024 * 1024


def semantic_text(text):
    # Punctuation/spacing corrections do not justify another image or invalidate one.
    return ''.join(c for c in unicodedata.normalize('NFKC', text) if c.isalnum()).casefold()


def local_timezone(timestamp):
    candidates = [os.environ.get('TZ', '').removeprefix(':')]
    zone_path = str(Path('/etc/localtime').resolve())
    if '/zoneinfo/' in zone_path:
        candidates.append(zone_path.split('/zoneinfo/', 1)[1])
    for candidate in candidates:
        if not candidate or candidate.startswith('/'):
            continue
        try:
            return candidate, ZoneInfo(candidate)
        except (ZoneInfoNotFoundError, ValueError):
            continue
    local = dt.datetime.fromtimestamp(timestamp).astimezone()
    offset = int(local.utcoffset().total_seconds() // 60)
    # Foundation accepts explicit GMT offsets; ambiguous abbreviations such as CST are never sent.
    name = f'GMT{"+" if offset >= 0 else "-"}{abs(offset) // 60:02d}:{abs(offset) % 60:02d}'
    return name, local.tzinfo


def window_at(timestamp, hours, day_start):
    name, zone = local_timezone(timestamp)
    local = dt.datetime.fromtimestamp(timestamp, zone)
    day = local.date() - dt.timedelta(days=int(local.hour < day_start))
    beginning = dt.datetime.combine(day, dt.time(day_start), tzinfo=zone)
    index = int((local - beginning).total_seconds() // (hours * 3600))
    start = beginning + dt.timedelta(hours=index * hours)
    end = start + dt.timedelta(hours=hours)
    return dict(window_start=start.timestamp(), window_end=end.timestamp(), logical_day=day.isoformat(),
                timezone=name)


def visit_evidence(context, start, end):
    """Only completed phone Visits can establish a place; an open visit is unknown."""
    result, seen = [], set()
    for row in context.db.execute("SELECT device_id,revision,payload FROM phone_source_snapshots WHERE kind='visits'"):
        snapshot = json.loads(row['payload'])
        if snapshot.get('state') not in ('enabled', 'foreground_only'):
            continue
        for visit in snapshot.get('records', []):
            arrival, departure = visit.get('start'), visit.get('end')
            if (visit.get('source_name') != 'CoreLocation visits' or arrival is None or departure is None
                    or visit.get('accuracy', 1e9) > 200 or departure <= arrival):
                continue
            overlap = min(end, departure) - max(start, arrival)
            if overlap < 300:
                continue
            key = (arrival, departure, visit.get('latitude'), visit.get('longitude'))
            if key in seen:
                continue
            seen.add(key)
            result.append(dict(id=visit['id'], device_id=row['device_id'], revision=row['revision'],
                               start=arrival, end=departure, overlap_seconds=overlap,
                               latitude=visit.get('latitude'), longitude=visit.get('longitude'),
                               title=(visit.get('title') or '').strip() or None))
    return sorted(result, key=lambda value: (-value['overlap_seconds'], value['id']))


def evidence_for(context, start, end):
    passages, versions, pending = [], {}, False
    summaries = {row['fingerprint']: row['result'] for row in context.db.execute(
        "SELECT fingerprint,result FROM recording_summaries WHERE state='done' AND result IS NOT NULL")}
    active = {row['fingerprint'] for row in context.db.execute(
        "SELECT fingerprint FROM recording_summaries WHERE state IN ('pending','running')")}
    for row in context.db.execute("SELECT id,revision,payload FROM sources WHERE deleted=0 ORDER BY id"):
        payload = json.loads(row['payload'])
        pending |= any(float(part['start']) < end and float(part['end']) > start
                       for part in payload.get('pending_transcription_ranges', []))
        spans = sorted((span for span in payload.get('spans', []) if start <= span['recorded_at'] < end),
                       key=lambda span: (span['recorded_at'], span['id']))
        if not spans:
            continue
        versions[row['id']] = row['revision']
        # Consume complete transcripts and complete matching summaries, never UI previews.
        groups = []
        for span in spans:
            if groups and span['recorded_at'] - groups[-1][-1]['recorded_at'] - min(60, len(groups[-1][-1]['text']) * 0.22) <= 300:
                groups[-1].append(span)
            else:
                groups.append([span])
        fingerprints = [digest('\n\n'.join(span['text'] for span in group)) for group in groups]
        pending |= any(fingerprint in active for fingerprint in fingerprints)
        complete_summaries = [summaries[fingerprint] for fingerprint in fingerprints if fingerprint in summaries]
        passages.append(dict(source_id=row['id'], source_revision=row['revision'],
                             summary='\n\n'.join(complete_summaries) or None, spans=spans))
    visits = visit_evidence(context, start, end)
    evidence = dict(passages=passages, visits=visits)
    semantic = canonical([(part['source_id'], [(span['id'], span['recorded_at'], span.get('speaker'), span.get('is_owner'), semantic_text(span['text']))
                                              for span in part['spans']]) for part in passages])
    return evidence, versions, digest(semantic), pending


class LifeIllustrations:
    def __init__(self, data):
        self.data = Path(data)
        self.directory = self.data / 'life-illustrations'
        self.assets = self.directory / 'assets'
        self.assets.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.directory / 'state.sqlite', timeout=10, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS settings (
                id INTEGER PRIMARY KEY CHECK(id=1),enabled INTEGER NOT NULL DEFAULT 0,
                interval_hours INTEGER NOT NULL DEFAULT 3,active_from REAL,updated_at REAL NOT NULL DEFAULT 0);
            INSERT OR IGNORE INTO settings(id) VALUES(1);
            CREATE TABLE IF NOT EXISTS slots (
                id TEXT PRIMARY KEY,window_start REAL NOT NULL,window_end REAL NOT NULL,
                logical_day TEXT NOT NULL,timezone TEXT NOT NULL,state TEXT NOT NULL,
                source_versions TEXT NOT NULL,evidence TEXT NOT NULL,semantic_hash TEXT NOT NULL,
                brief TEXT,request_id TEXT,response_id TEXT,attempt INTEGER NOT NULL DEFAULT 0,
                retry_at REAL NOT NULL DEFAULT 0,error TEXT,place TEXT,asset_sha256 TEXT,thumbnail_sha256 TEXT,
                width INTEGER,height INTEGER,created_at REAL NOT NULL,updated_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS changes (
                cursor INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL,payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS slots_window ON slots(window_start,window_end);
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL);
        ''')

    def close(self):
        self.db.close()

    @contextmanager
    def write(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    def settings(self, availability):
        row = dict(self.db.execute('SELECT * FROM settings WHERE id=1').fetchone())
        row.pop('id'); row.pop('active_from')
        row['enabled'] = bool(row['enabled'])
        row.update(availability, day_start_hour=read_day_start_hour(self.data))
        row['pending_count'] = self.db.execute("SELECT COUNT(*) FROM slots WHERE state IN ('pending','preparing','submitting')").fetchone()[0]
        row['needs_review_count'] = self.db.execute("SELECT COUNT(*) FROM slots WHERE state='needs_review'").fetchone()[0]
        return row

    def update_settings(self, body, availability, now=None):
        if not isinstance(body, dict) or set(body) - {'enabled', 'interval_hours'}:
            raise ValueError('Only enabled and interval_hours may be changed')
        if 'enabled' in body and type(body['enabled']) is not bool:
            raise ValueError('enabled must be boolean')
        if 'interval_hours' in body and (type(body['interval_hours']) is not int or body['interval_hours'] not in INTERVALS):
            raise ValueError('interval_hours must be 2, 3, 4 or 6')
        now = time.time() if now is None else now
        with self.write():
            old = self.db.execute('SELECT * FROM settings WHERE id=1').fetchone()
            enabled, hours = body.get('enabled', bool(old['enabled'])), body.get('interval_hours', old['interval_hours'])
            active = old['active_from']
            if enabled and not old['enabled']:
                active = window_at(now, hours, read_day_start_hour(self.data))['window_start']
            self.db.execute('UPDATE settings SET enabled=?,interval_hours=?,active_from=?,updated_at=? WHERE id=1',
                            (int(enabled), hours, active, now))
        return self.settings(availability)

    def publish(self, row, deleted=False):
        if deleted:
            item = dict(id=row['id'], deleted=True, updated_at=row['updated_at'])
        else:
            item = {key: row[key] for key in ('id', 'window_start', 'window_end', 'logical_day', 'timezone', 'place',
                    'asset_sha256', 'thumbnail_sha256', 'width', 'height', 'created_at', 'updated_at')}
            item.update(deleted=False, source_ids=sorted(json.loads(row['source_versions'])))
        self.db.execute('INSERT INTO changes(id,payload) VALUES(?,?)', (row['id'], canonical(item)))
        return item

    def manifest(self, cursor='0', limit=100):
        if not isinstance(cursor, str) or not re.fullmatch(r'\d{1,20}', cursor) or int(cursor) > 2**63 - 1:
            raise ValueError('Invalid illustration cursor')
        if type(limit) is not int or not 1 <= limit <= 200:
            raise ValueError('limit must be 1...200')
        rows = self.db.execute('SELECT cursor,payload FROM changes WHERE cursor>? ORDER BY cursor LIMIT ?',
                               (int(cursor), limit + 1)).fetchall()
        visible = rows[:limit]
        items = []
        for change in visible:
            item = json.loads(change['payload'])
            if not item['deleted']:
                current = self.db.execute('SELECT state,updated_at FROM slots WHERE id=?', (item['id'],)).fetchone()
                if not current or current['state'] != 'ready':
                    # New/lagging clients must not fetch an asset that a later event already deleted.
                    item = dict(id=item['id'], deleted=True, updated_at=current['updated_at'] if current else item['updated_at'])
            items.append(item)
        return dict(items=items,
                    next_cursor=str(visible[-1]['cursor']) if visible else cursor, has_more=len(rows) > limit)

    def status(self, after=0, limit=50):
        if type(after) is not int or after < 0 or type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError('Invalid illustration status page')
        rows = self.db.execute('''SELECT rowid,id,window_start,window_end,state,error,updated_at FROM slots
            WHERE rowid>? ORDER BY rowid LIMIT ?''', (after, limit + 1)).fetchall()
        return dict(items=[{key: row[key] for key in row.keys() if key != 'rowid'} for row in rows[:limit]],
                    next_cursor=rows[limit - 1]['rowid'] if len(rows) > limit else None)

    def delete(self, identity, now=None, state='deleted'):
        identity = str(uuid.UUID(identity))
        now = time.time() if now is None else now
        with self.write():
            row = self.db.execute('SELECT * FROM slots WHERE id=?', (identity,)).fetchone()
            if not row:
                raise ValueError('Unknown illustration')
            if row['state'] not in ('deleted', 'invalid'):
                self.db.execute('''UPDATE slots SET state=?,evidence='{}',brief=NULL,source_versions='{}',
                    error=NULL,updated_at=? WHERE id=?''', (state, now, identity))
                row = self.db.execute('SELECT * FROM slots WHERE id=?', (identity,)).fetchone()
                result = self.publish(row, deleted=True)
            else:
                result = dict(id=identity, deleted=True, updated_at=row['updated_at'])
        self.prune_assets()
        return result

    def prune_assets(self):
        with self.write():
            referenced = {value for row in self.db.execute("SELECT asset_sha256,thumbnail_sha256 FROM slots WHERE state='ready'") for value in row if value}
            for path in self.assets.glob('*.png'):
                if path.stem not in referenced:
                    path.unlink(missing_ok=True)

    def reconcile(self, context):
        signature = canonical([context.revision, [tuple(row) for row in context.db.execute(
            "SELECT device_id,revision FROM phone_source_snapshots WHERE kind='visits' ORDER BY device_id")]])
        previous = self.db.execute("SELECT value FROM metadata WHERE key='reconciled_sources'").fetchone()
        if previous and previous['value'] == signature:
            return
        for row in self.db.execute("SELECT * FROM slots WHERE state NOT IN ('deleted','invalid','skipped')").fetchall():
            _, versions, semantic, _ = evidence_for(context, row['window_start'], row['window_end'])
            invalid_visit = False
            for visit in json.loads(row['evidence']).get('visits', []):
                current = context.db.execute("SELECT payload FROM phone_source_snapshots WHERE device_id=? AND kind='visits'", (visit['device_id'],)).fetchone()
                if not current:
                    invalid_visit = True; break
                snapshot = json.loads(current['payload'])
                # A rolling snapshot aging out old visits is not a deletion.
                covered = snapshot.get('window_start', 0) <= visit['start'] and snapshot.get('window_end', 0) >= visit['end']
                if snapshot.get('state') not in ('enabled', 'foreground_only'):
                    invalid_visit = True; break
                if covered:
                    record = next((item for item in snapshot.get('records', []) if item['id'] == visit['id']), None)
                    if (record is None or record.get('start') != visit['start'] or record.get('end') != visit['end']
                            or record.get('source_name') != 'CoreLocation visits' or record.get('accuracy', 1e9) > 200
                            or record.get('latitude') != visit.get('latitude') or record.get('longitude') != visit.get('longitude')
                            or (record.get('title') or '').strip() != (visit['title'] or '')):
                        invalid_visit = True; break
            if semantic != row['semantic_hash'] or invalid_visit:
                # Any semantic correction withdraws the old picture. Never auto-charge for a replacement.
                self.delete(row['id'], state='invalid')
            elif canonical(versions) != row['source_versions']:
                self.db.execute("UPDATE slots SET source_versions=? WHERE id=? AND state NOT IN ('deleted','invalid')", (canonical(versions), row['id']))
        self.db.execute("INSERT OR REPLACE INTO metadata VALUES('reconciled_sources',?)", (signature,))

    def scan(self, context, now=None):
        now = time.time() if now is None else now
        self.reconcile(context)
        settings = self.db.execute('SELECT * FROM settings WHERE id=1').fetchone()
        if not settings['enabled'] or settings['active_from'] is None:
            return
        candidates = {}
        for row in context.db.execute('SELECT payload FROM sources WHERE deleted=0'):
            for span in json.loads(row['payload']).get('spans', []):
                if span['recorded_at'] < settings['active_from']:
                    continue
                window = window_at(span['recorded_at'], settings['interval_hours'], read_day_start_hour(self.data))
                if window['window_end'] + SETTLE_SECONDS <= now:
                    candidates[window['window_start']] = window
        for start, window in sorted(candidates.items()):
            end = window['window_end']
            if self.db.execute('SELECT 1 FROM slots WHERE window_start<? AND window_end>?', (end, start)).fetchone():
                continue  # Interval changes and re-enabling cannot bill an overlapping window again.
            evidence, versions, semantic, pending = evidence_for(context, start, end)
            if pending:
                continue
            text = '\n'.join(span['text'] for part in evidence['passages'] for span in part['spans'])
            if len(semantic_text(text)) < 40:
                continue
            identity = str(uuid.uuid5(uuid.NAMESPACE_URL, f'momo-life-v1:{start}:{end}'))
            place = next((visit['title'] for visit in evidence['visits'] if visit['title']), None)
            self.db.execute('''INSERT OR IGNORE INTO slots
                (id,window_start,window_end,logical_day,timezone,state,source_versions,evidence,semantic_hash,place,created_at,updated_at)
                VALUES(?,?,?,?,?,'pending',?,?,?,?,?,?)''',
                (identity, start, end, window['logical_day'], window['timezone'], canonical(versions), canonical(evidence),
                 semantic, place, now, now))

    def asset(self, sha):
        if not isinstance(sha, str) or not re.fullmatch(r'[a-f0-9]{64}', sha):
            raise ValueError('Invalid asset hash')
        if not self.db.execute("SELECT 1 FROM slots WHERE state='ready' AND (asset_sha256=? OR thumbnail_sha256=?)", (sha, sha)).fetchone():
            raise FileNotFoundError('Illustration asset is unavailable')
        path = self.assets / (sha + '.png')
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != sha:
            raise ValueError('Illustration asset integrity check failed')
        return raw

    def save_image(self, identity, raw, now=None):
        from PIL import Image, ImageOps
        if not raw or len(raw) > MAX_ASSET_BYTES:
            raise ValueError('Invalid image size')
        with Image.open(io.BytesIO(raw)) as candidate:
            if candidate.format != 'PNG' or candidate.width * candidate.height > 16_000_000:
                raise ValueError('Expected a bounded PNG image')
            candidate.verify()
        with Image.open(io.BytesIO(raw)) as candidate:
            candidate.load()
            picture = ImageOps.fit(candidate.convert('RGB'), (1360, 1020), method=Image.Resampling.LANCZOS)
        original, thumbnail = io.BytesIO(), io.BytesIO()
        picture.save(original, format='PNG', optimize=True)
        picture.thumbnail((680, 510), Image.Resampling.LANCZOS)
        picture.save(thumbnail, format='PNG', optimize=True)
        encoded = [original.getvalue(), thumbnail.getvalue()]
        hashes = [hashlib.sha256(value).hexdigest() for value in encoded]
        # Store pixels before the manifest; a crash cannot publish a missing image.
        with self.write():
            row = self.db.execute('SELECT * FROM slots WHERE id=?', (identity,)).fetchone()
            if not row or row['state'] != 'submitting':
                return
            for sha, value in zip(hashes, encoded):
                path = self.assets / (sha + '.png')
                temp = path.with_suffix('.new')
                with open(temp, 'wb') as file:
                    os.chmod(temp, 0o600); file.write(value); file.flush(); os.fsync(file.fileno())
                temp.replace(path)
            now = time.time() if now is None else now
            self.db.execute('''UPDATE slots SET state='ready',asset_sha256=?,thumbnail_sha256=?,width=1360,height=1020,
                updated_at=?,error=NULL WHERE id=?''', (*hashes, now, identity))
            self.publish(self.db.execute('SELECT * FROM slots WHERE id=?', (identity,)).fetchone())

    def recover(self):
        self.db.execute("UPDATE slots SET state='pending' WHERE state='preparing'")
        for row in self.db.execute("SELECT id FROM slots WHERE state='submitting'").fetchall():
            spool = self.directory / (row['id'] + '.result.png')
            if spool.exists():
                try:
                    self.save_image(row['id'], spool.read_bytes())
                except (ValueError, OSError):
                    self.db.execute("UPDATE slots SET state='needs_review',error='invalid_image' WHERE id=?", (row['id'],))
                spool.unlink(missing_ok=True)
            else:
                # Codex store=False has no durable retrieval API. Replaying could charge twice.
                self.db.execute("UPDATE slots SET state='needs_review',error='generation_outcome_unknown' WHERE id=?", (row['id'],))

    def advance(self, generator, context, now=None):
        now = time.time() if now is None else now
        if not generator.availability()['supported'] or not self.db.execute('SELECT enabled FROM settings WHERE id=1').fetchone()[0]:
            return
        row = self.db.execute("SELECT * FROM slots WHERE state='pending' AND retry_at<=? ORDER BY window_start LIMIT 1", (now,)).fetchone()
        if not row:
            return
        evidence, _, _, pending = evidence_for(context, row['window_start'], row['window_end'])
        if pending:
            return
        if not self.db.execute("UPDATE slots SET state='preparing' WHERE id=? AND state='pending'", (row['id'],)).rowcount:
            return
        try:
            brief = row['brief'] or generator.prepare(evidence)
            if brief.strip() == 'SKIP':
                self.db.execute("UPDATE slots SET state='skipped',brief=NULL,error=NULL WHERE id=? AND state='preparing'", (row['id'],))
                return
            self.reconcile(context)
            if not self.db.execute("SELECT 1 FROM slots WHERE id=? AND state='preparing'", (row['id'],)).fetchone():
                return
            pending = evidence_for(context, row['window_start'], row['window_end'])[3]
            if pending or not self.db.execute('SELECT enabled FROM settings WHERE id=1').fetchone()[0] or not generator.availability()['supported']:
                self.db.execute("UPDATE slots SET state='pending',brief=? WHERE id=? AND state='preparing'", (brief, row['id']))
                return
            request_id = row['request_id'] or str(uuid.uuid4())
            with self.write():
                if not self.db.execute('SELECT enabled FROM settings WHERE id=1').fetchone()[0]:
                    self.db.execute("UPDATE slots SET state='pending' WHERE id=? AND state='preparing'", (row['id'],))
                    return
                claimed = self.db.execute("UPDATE slots SET state='submitting',brief=?,request_id=?,attempt=attempt+1,updated_at=? WHERE id=? AND state='preparing'",
                                          (brief, request_id, now, row['id'])).rowcount
            if not claimed:
                return
            def remember(response_id):
                self.db.execute("UPDATE slots SET response_id=? WHERE id=? AND state='submitting'", (response_id, row['id']))
            raw = generator.generate(brief, request_id, remember)
            spool = self.directory / (row['id'] + '.result.png')
            with open(spool, 'wb') as file:
                os.chmod(spool, 0o600); file.write(raw); file.flush(); os.fsync(file.fileno())
            self.reconcile(context)
            self.save_image(row['id'], raw)
            spool.unlink(missing_ok=True)
        except Exception as error:
            current = self.db.execute('SELECT state,attempt FROM slots WHERE id=?', (row['id'],)).fetchone()
            if current['state'] not in ('preparing', 'submitting'):
                return
            safe_retry = current['state'] == 'preparing' or getattr(error, 'safe_to_retry', False)
            attempts = max(current['attempt'], row['attempt'] + 1)
            state = 'pending' if safe_retry and attempts < 3 else ('failed' if safe_retry else 'needs_review')
            code = 'service_unavailable' if safe_retry else 'generation_outcome_unknown'
            self.db.execute('UPDATE slots SET state=?,attempt=?,retry_at=?,error=?,updated_at=? WHERE id=? AND state=?',
                            (state, attempts, now + 60 * 2**attempts, code, now, row['id'], current['state']))
