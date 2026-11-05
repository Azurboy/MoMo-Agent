"""One durable, opt-in life-illustration queue. Views only read finished assets."""
from contextlib import contextmanager
import datetime as dt
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import threading
import time
import unicodedata
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from context_store import canonical, digest, read_day_start_hour

INTERVALS = (2, 3, 4, 6)
SETTLE_SECONDS = 600
EPISODE_GAP_SECONDS = 600
MIN_SUBSTANTIVE_CHARS = 80
MIN_MEANINGFUL_CLAUSES = 4
MAX_ASSET_BYTES = 8 * 1024 * 1024

EDGE_FILLER_RE = re.compile(
    r'^(?:嗯+|啊+|哦+|噢+|呃+|额+|唉+|哎呀|哎哟|哎+|哈+|嘿+|唔+|喔+|哇+|呀+|啦+|吧+|呢+|吗+|嘛+|呐+|呗+|嘞+|咯+|哼+|哟+|喂+|'
    r'那个|就是说|就是|然后呢|然后|所以说|所以|其实|反正|好吧|好的|好呀|好嘞|行吧|行啊|对对+|对的|是的|对啊|是啊|'
    r'没错|没问题|知道了|明白|了解|谢谢|你好|拜拜|再见|ok+|okay+|yeah+|yep+|uh+|um+|ah+|oh+|hmm+|hm+)+|'
    r'(?:嗯+|啊+|哦+|噢+|呃+|额+|唉+|哈+|呀+|啦+|吧+|呢+|吗+|嘛+|呐+|呗+|嘞+|咯+|哼+|哟+|ok+|okay+|yeah+|uh+|um+|hmm+)+$',
    re.IGNORECASE,
)

PURE_FILLER_RE = re.compile(
    r'^(?:嗯|啊|哦|噢|呃|额|唉|哎|哈|嘿|唔|喔|哇|呀|啦|吧|呢|吗|嘛|呐|呗|嘞|咯|哼|哟|喂|'
    r'好|行|对|是|中|可以|好的|好吧|好呀|好嘞|行吧|行啊|对的|是的|对啊|是啊|没错|没问题|'
    r'那个|就是|然后|所以|其实|反正|知道|知道了|明白|了解|谢谢|不客气|你好|拜拜|再见|'
    r'ok|okay|yeah|yep|nope|uh|um|ah|oh|hmm|hm|well|right|sure)+$',
    re.IGNORECASE,
)


def semantic_text(text):
    # Punctuation/spacing corrections do not justify another image or invalidate one.
    return ''.join(c for c in unicodedata.normalize('NFKC', text) if c.isalnum()).casefold()


def substantive_clause(raw_clause):
    clause = ''.join(ch for ch in unicodedata.normalize('NFKC', raw_clause) if ch.isalnum())
    if not clause or PURE_FILLER_RE.fullmatch(clause):
        return ''
    previous = None
    while clause and clause != previous:
        previous = clause
        clause = EDGE_FILLER_RE.sub('', clause)
    if not clause or PURE_FILLER_RE.fullmatch(clause):
        return ''
    if len(set(clause.casefold())) == 1 and len(clause) <= 6:
        return ''
    return clause


def conversation_density(text):
    normalized = unicodedata.normalize('NFKC', text)
    alnum_total = sum(1 for ch in normalized if ch.isalnum())
    clauses = [substantive_clause(part) for part in re.split(r'[，,。！？!?；;：:\s…—～~、]+', normalized)]
    meaningful = [clause for clause in clauses if len(clause) >= 2]
    substantive_chars = sum(len(clause) for clause in meaningful)
    return alnum_total, substantive_chars, len(meaningful)


def is_dense_conversation(text, duration_seconds=60.0):
    alnum_total, substantive_chars, meaningful_clauses = conversation_density(text)
    if substantive_chars < MIN_SUBSTANTIVE_CHARS or meaningful_clauses < MIN_MEANINGFUL_CLAUSES:
        return False
    if alnum_total > 0 and substantive_chars / alnum_total < 0.35 and substantive_chars < 160:
        return False
    minutes = max(1.0, float(duration_seconds) / 60.0)
    if substantive_chars / minutes < 20.0 and substantive_chars < 180:
        return False
    return True


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
            if (visit.get('source_name') != 'CoreLocation visits' or not valid_location(visit, 200)
                    or not finite_number(arrival) or not finite_number(departure) or departure - arrival < 300):
                continue
            overlap = min(end, departure) - max(start, arrival)
            if overlap <= 0 or overlap < min(300.0, max(1.0, end - start)):
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


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def valid_location(record, accuracy_limit):
    lat, lon, accuracy = (record.get(key) for key in ('latitude', 'longitude', 'accuracy'))
    return (all(finite_number(value) for value in (lat, lon, accuracy))
            and -90 <= lat <= 90 and -180 <= lon <= 180 and 0 <= accuracy <= accuracy_limit)


def trajectory_evidence(context, day_start_ts, window_end_ts):
    points, seen = [], set()
    for row in context.db.execute("SELECT device_id,revision,payload FROM phone_source_snapshots WHERE kind='visits' ORDER BY device_id"):
        snapshot = json.loads(row['payload'])
        if snapshot.get('state') not in ('enabled', 'foreground_only'):
            continue
        for record in snapshot.get('records', []):
            start, end = record.get('start'), record.get('end')
            stationary = record.get('source_name') == 'CoreLocation visits'
            if not stationary and record.get('source_name') != 'CoreLocation significant_change':
                continue
            if not valid_location(record, 200 if stationary else 500) or not finite_number(start):
                continue
            if stationary:
                if not finite_number(end) or end <= start or end <= day_start_ts or start > window_end_ts:
                    continue
            elif not day_start_ts <= start <= window_end_ts:
                continue
            key = (stationary, start, end, record['latitude'], record['longitude'])
            if key in seen:
                continue
            seen.add(key)
            points.append(dict(id=record['id'], device_id=row['device_id'], revision=row['revision'],
                start=start, end=end, timestamp=max(start, day_start_ts),
                end_timestamp=min(end, window_end_ts) if stationary else None,
                latitude=record['latitude'], longitude=record['longitude'],
                kind='visit' if stationary else 'waypoint', title=(record.get('title') or '').strip() or None))
    points.sort(key=lambda point: (point['timestamp'], point['id']))
    # Keep stays and the trajectory endpoints, then evenly sample transit fixes within the wire bound.
    if len(points) > 64:
        required = {0, len(points) - 1} | {i for i, point in enumerate(points) if point['kind'] == 'visit'}
        if len(required) > 64:
            indices = sorted(required)
            required = {indices[round(i * (len(indices) - 1) / 63)] for i in range(64)}
        remaining = [i for i in range(len(points)) if i not in required]
        count = min(64 - len(required), len(remaining))
        required.update(remaining[round(i * (len(remaining) - 1) / max(1, count - 1))] for i in range(count))
        points = [points[i] for i in sorted(required)]
    return points


def location_evidence_is_current(context, point):
    row = context.db.execute("SELECT payload FROM phone_source_snapshots WHERE device_id=? AND kind='visits'", (point['device_id'],)).fetchone()
    if not row:
        return False
    snapshot = json.loads(row['payload'])
    if snapshot.get('state') not in ('enabled', 'foreground_only'):
        return False
    end = point.get('end') or point['start']
    if not (snapshot.get('window_start', 0) <= point['start'] and snapshot.get('window_end', 0) >= end):
        return True  # Aging out of the rolling window is not revocation.
    record = next((record for record in snapshot.get('records', []) if record['id'] == point['id']), None)
    stationary = point.get('kind', 'visit') == 'visit'
    return (record is not None and valid_location(record, 200 if stationary else 500)
            and record.get('source_name') == ('CoreLocation visits' if stationary else 'CoreLocation significant_change')
            and all(record.get(key) == point.get(key) for key in ('start', 'end', 'latitude', 'longitude'))
            and (record.get('title') or '').strip() == (point.get('title') or ''))


_ILLUSTRATION_DB_LOCK = threading.Lock()
_INITIALIZED_ILLUSTRATION_DBS = set()


def _preload_source_entries(context):
    entries = []
    for row in context.db.execute("SELECT id,revision,payload FROM sources WHERE deleted=0 ORDER BY id"):
        payload = json.loads(row['payload'])
        spans = payload.get('spans', [])
        pending_ranges = [(float(part['start']), float(part['end']))
                          for part in payload.get('pending_transcription_ranges', [])]
        if spans:
            min_ts = min(span['recorded_at'] for span in spans)
            max_ts = max(span['recorded_at'] for span in spans)
        else:
            min_ts = max_ts = None
        entries.append((row['id'], row['revision'], spans, pending_ranges, min_ts, max_ts))
    return entries


def evidence_for(context, start, end, source_entries=None, include_summaries=True):
    passages, versions, pending = [], {}, False
    if include_summaries:
        summaries = {row['fingerprint']: row['result'] for row in context.db.execute(
            "SELECT fingerprint,result FROM recording_summaries WHERE state='done' AND result IS NOT NULL")}
        active = {row['fingerprint'] for row in context.db.execute(
            "SELECT fingerprint FROM recording_summaries WHERE state IN ('pending','running')")}
    else:
        summaries, active = {}, set()
    entries = _preload_source_entries(context) if source_entries is None else source_entries
    for source_id, revision, all_spans, pending_ranges, min_ts, max_ts in entries:
        if pending_ranges:
            pending |= any(p_start < end and p_end > start for p_start, p_end in pending_ranges)
        if min_ts is None or max_ts < start or min_ts >= end:
            continue
        spans = sorted((span for span in all_spans if start <= span['recorded_at'] < end),
                       key=lambda span: (span['recorded_at'], span['id']))
        if not spans:
            continue
        versions[source_id] = revision
        complete_summaries = []
        if include_summaries:
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
        passages.append(dict(source_id=source_id, source_revision=revision,
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
        db_file = self.directory / 'state.sqlite'
        self.db = sqlite3.connect(db_file, timeout=10, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        try:
            st = os.stat(db_file)
            db_id = (str(db_file.resolve()), st.st_dev, st.st_ino)
        except OSError:
            db_id = None
        if db_id is None or db_id not in _INITIALIZED_ILLUSTRATION_DBS:
            with _ILLUSTRATION_DB_LOCK:
                if db_id is None or db_id not in _INITIALIZED_ILLUSTRATION_DBS:
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
                    self.ensure_columns()
                    if db_id is None:
                        try:
                            st = os.stat(db_file)
                            db_id = (str(db_file.resolve()), st.st_dev, st.st_ino)
                        except OSError:
                            db_id = None
                    if db_id is not None:
                        _INITIALIZED_ILLUSTRATION_DBS.add(db_id)

    def ensure_columns(self):
        with self.write():
            columns = {row['name'] for row in self.db.execute('PRAGMA table_info(slots)')}
            for name, declaration in dict(summary='TEXT', latitude='REAL', longitude='REAL',
                    place_start='REAL', place_end='REAL', route_points="TEXT NOT NULL DEFAULT '[]'").items():
                if name not in columns:
                    self.db.execute(f'ALTER TABLE slots ADD COLUMN {name} {declaration}')

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
                    'summary', 'latitude', 'longitude', 'place_start', 'place_end',
                    'asset_sha256', 'thumbnail_sha256', 'width', 'height', 'created_at', 'updated_at')}
            item.update(deleted=False, source_ids=sorted(json.loads(row['source_versions'])))
            item['route_points'] = [{key: point.get(key) for key in
                ('latitude', 'longitude', 'timestamp', 'end_timestamp', 'kind', 'title')}
                for point in json.loads(row['route_points'])]
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
                    summary=NULL,place=NULL,latitude=NULL,longitude=NULL,place_start=NULL,place_end=NULL,route_points='[]',
                    error=NULL,updated_at=? WHERE id=?''', (state, now, identity))
                row = self.db.execute('SELECT * FROM slots WHERE id=?', (identity,)).fetchone()
                result = self.publish(row, deleted=True)
                self.db.execute('UPDATE changes SET payload=? WHERE id=?', (canonical(result), identity))
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
        rows = self.db.execute("SELECT * FROM slots WHERE state NOT IN ('deleted','invalid','skipped')").fetchall()
        source_entries = _preload_source_entries(context) if rows else []
        for row in rows:
            _, versions, semantic, _ = evidence_for(
                context, row['window_start'], row['window_end'],
                source_entries=source_entries, include_summaries=False
            )
            evidence = json.loads(row['evidence'])
            invalid_visit = any(not location_evidence_is_current(context, point)
                                for point in evidence.get('visits', []) + evidence.get('trajectory', []))
            if semantic != row['semantic_hash'] or invalid_visit:
                # Any semantic correction withdraws the old picture. Never auto-charge for a replacement.
                self.delete(row['id'], state='invalid')
            elif canonical(versions) != row['source_versions']:
                self.db.execute("UPDATE slots SET source_versions=? WHERE id=? AND state NOT IN ('deleted','invalid')", (canonical(versions), row['id']))
        self.db.execute("INSERT OR REPLACE INTO metadata VALUES('reconciled_sources',?)", (signature,))

    def _episodes(self, context, day_start_hour):
        spans, pending_ranges = [], []
        for row in context.db.execute('SELECT id,payload FROM sources WHERE deleted=0 ORDER BY id'):
            payload = json.loads(row['payload'])
            for part in payload.get('pending_transcription_ranges', []):
                pending_ranges.append((float(part['start']), float(part['end'])))
            for span in payload.get('spans', []):
                spans.append((float(span['recorded_at']), row['id'], span['id'], span['text']))
        spans.sort(key=lambda item: (item[0], item[1], item[2]))
        episodes = []
        for recorded_at, _, _, text in spans:
            if conversation_density(text)[1] < 2:
                continue
            name, zone = local_timezone(recorded_at)
            local = dt.datetime.fromtimestamp(recorded_at, zone)
            logical_day = (local.date() - dt.timedelta(days=int(local.hour < day_start_hour))).isoformat()
            est_end = recorded_at + max(2.0, min(60.0, len(text) * 0.22))
            if (episodes and episodes[-1]['logical_day'] == logical_day
                    and recorded_at - episodes[-1]['speech_end'] <= EPISODE_GAP_SECONDS):
                episodes[-1]['speech_end'] = max(episodes[-1]['speech_end'], est_end)
                episodes[-1]['last_recorded_at'] = max(episodes[-1]['last_recorded_at'], recorded_at)
            else:
                episodes.append(dict(
                    start=recorded_at,
                    speech_end=est_end,
                    last_recorded_at=recorded_at,
                    logical_day=logical_day,
                    timezone=name,
                ))
        for index, episode in enumerate(episodes):
            upper = max(episode['speech_end'], episode['last_recorded_at'] + 1.0, episode['start'] + 60.0)
            if index + 1 < len(episodes):
                upper = min(upper, episodes[index + 1]['start'])
            episode['window_start'] = episode['start']
            episode['window_end'] = max(episode['last_recorded_at'] + 1e-3, upper)
        return episodes, pending_ranges

    def scan(self, context, now=None):
        now = time.time() if now is None else now
        self.reconcile(context)
        settings = self.db.execute('SELECT * FROM settings WHERE id=1').fetchone()
        if not settings['enabled'] or settings['active_from'] is None:
            return
        day_start_hour = read_day_start_hour(self.data)
        episodes, pending_ranges = self._episodes(context, day_start_hour)
        for episode in episodes:
            start, end = episode['window_start'], episode['window_end']
            if start < settings['active_from']:
                continue
            # interval_hours paces batch generation checkpoints; each dense conversation in the batch gets its own slot.
            batch = window_at(episode['last_recorded_at'], settings['interval_hours'], day_start_hour)
            if batch['window_end'] + SETTLE_SECONDS > now or episode['speech_end'] + SETTLE_SECONDS > now:
                continue
            if any(p_start < episode['speech_end'] + EPISODE_GAP_SECONDS and p_end > start - EPISODE_GAP_SECONDS
                   for p_start, p_end in pending_ranges):
                continue
            if self.db.execute('SELECT 1 FROM slots WHERE window_start<? AND window_end>?', (end, start)).fetchone():
                continue  # Interval changes and re-enabling cannot bill an overlapping conversation again.
            evidence, versions, semantic, pending = evidence_for(context, start, end)
            if pending:
                continue
            text = '\n'.join(span['text'] for part in evidence['passages'] for span in part['spans'])
            if not is_dense_conversation(text, episode['speech_end'] - start):
                continue
            identity = str(uuid.uuid5(uuid.NAMESPACE_URL, f'momo-life-v1:{start}:{end}'))
            primary = evidence['visits'][0] if evidence['visits'] else {}
            _, zone = local_timezone(start)
            day_start = dt.datetime.combine(dt.date.fromisoformat(episode['logical_day']),
                dt.time(day_start_hour), tzinfo=zone).timestamp()
            route = trajectory_evidence(context, day_start, max(end, batch['window_end']))
            evidence['trajectory'] = route
            self.db.execute('''INSERT OR IGNORE INTO slots
                (id,window_start,window_end,logical_day,timezone,state,source_versions,evidence,semantic_hash,
                 place,latitude,longitude,place_start,place_end,route_points,created_at,updated_at)
                VALUES(?,?,?,?,?,'pending',?,?,?,?,?,?,?,?,?,?,?)''',
                (identity, start, end, episode['logical_day'], episode['timezone'], canonical(versions), canonical(evidence),
                 semantic, primary.get('title'), primary.get('latitude'), primary.get('longitude'),
                 primary.get('start'), primary.get('end'), canonical(route), now, now))

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
            has_alpha = 'A' in candidate.getbands() or 'transparency' in candidate.info
            artwork = candidate.convert('RGBA' if has_alpha else 'RGB')
            has_transparent_ground = has_alpha and artwork.getchannel('A').getextrema()[0] < 200
            if has_transparent_ground:
                alpha = artwork.getchannel('A')
                bounds = alpha.point(lambda value: 255 if value > 24 else 0).getbbox()
                if bounds is None:
                    raise ValueError('Illustration contains no visible artwork')
                artwork.putalpha(alpha.point(lambda value: value if value > 24 else 0))
                left, top, right, bottom = bounds
                artwork = artwork.crop((max(0, left - 2), max(0, top - 2),
                                        min(artwork.width, right + 2), min(artwork.height, bottom + 2)))
            visible = Image.new('RGBA', artwork.size, '#FAF9F5')
            visible.alpha_composite(artwork.convert('RGBA'))
            if all(low == high for low, high in visible.convert('RGB').getextrema()):
                raise ValueError('Illustration contains no visible variation')
            if has_transparent_ground:
                from life_illustration_sticker import kiss_cut_sticker
                picture, preview = kiss_cut_sticker(artwork)
            else:
                picture = ImageOps.fit(artwork, (1024, 1024), method=Image.Resampling.LANCZOS)
                preview = ImageOps.fit(picture, (512, 512), method=Image.Resampling.LANCZOS)
        original, thumbnail = io.BytesIO(), io.BytesIO()
        picture.save(original, format='PNG', optimize=True)
        preview.save(thumbnail, format='PNG', optimize=True)
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
            self.db.execute('''UPDATE slots SET state='ready',asset_sha256=?,thumbnail_sha256=?,width=1024,height=1024,
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
            return False
        row, evidence = None, None
        for candidate in self.db.execute("SELECT * FROM slots WHERE state='pending' AND retry_at<=? ORDER BY window_start", (now,)).fetchall():
            cand_evidence, _, _, pending = evidence_for(context, candidate['window_start'], candidate['window_end'])
            if not pending:
                cand_evidence['visits'] = json.loads(candidate['evidence']).get('visits', [])
                row, evidence = candidate, cand_evidence
                break
        if not row:
            return False
        if not self.db.execute("UPDATE slots SET state='preparing' WHERE id=? AND state='pending'", (row['id'],)).rowcount:
            return False
        try:
            from life_illustration_generator import parse_scene_output
            summary, brief = (row['summary'], row['brief']) if row['brief'] else parse_scene_output(generator.prepare(evidence))
            if brief.strip() == 'SKIP':
                self.db.execute("UPDATE slots SET state='skipped',brief=NULL,error=NULL WHERE id=? AND state='preparing'", (row['id'],))
                return True
            self.reconcile(context)
            if not self.db.execute("SELECT 1 FROM slots WHERE id=? AND state='preparing'", (row['id'],)).fetchone():
                return True
            pending = evidence_for(context, row['window_start'], row['window_end'])[3]
            if pending or not self.db.execute('SELECT enabled FROM settings WHERE id=1').fetchone()[0] or not generator.availability()['supported']:
                self.db.execute("UPDATE slots SET state='pending',brief=?,summary=? WHERE id=? AND state='preparing'", (brief, summary, row['id']))
                return False
            request_id = row['request_id'] or str(uuid.uuid4())
            with self.write():
                if not self.db.execute('SELECT enabled FROM settings WHERE id=1').fetchone()[0]:
                    self.db.execute("UPDATE slots SET state='pending' WHERE id=? AND state='preparing'", (row['id'],))
                    return False
                claimed = self.db.execute("UPDATE slots SET state='submitting',brief=?,summary=?,request_id=?,attempt=attempt+1,updated_at=? WHERE id=? AND state='preparing'",
                                          (brief, summary, request_id, now, row['id'])).rowcount
            if not claimed:
                return False
            def remember(response_id):
                self.db.execute("UPDATE slots SET response_id=? WHERE id=? AND state='submitting'", (response_id, row['id']))
            raw = generator.generate(brief, request_id, remember)
            spool = self.directory / (row['id'] + '.result.png')
            with open(spool, 'wb') as file:
                os.chmod(spool, 0o600); file.write(raw); file.flush(); os.fsync(file.fileno())
            self.reconcile(context)
            self.save_image(row['id'], raw)
            spool.unlink(missing_ok=True)
            return True
        except Exception as error:
            current = self.db.execute('SELECT state,attempt FROM slots WHERE id=?', (row['id'],)).fetchone()
            if current['state'] not in ('preparing', 'submitting'):
                return False
            safe_retry = current['state'] == 'preparing' or getattr(error, 'safe_to_retry', False)
            attempts = max(current['attempt'], row['attempt'] + 1)
            state = 'pending' if safe_retry and attempts < 3 else ('failed' if safe_retry else 'needs_review')
            code = 'service_unavailable' if safe_retry else 'generation_outcome_unknown'
            self.db.execute('UPDATE slots SET state=?,attempt=?,retry_at=?,error=?,updated_at=? WHERE id=? AND state=?',
                            (state, attempts, now + 60 * 2**attempts, code, now, row['id'], current['state']))
            return False
