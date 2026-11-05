"""MoMo source replica and delivery checkpoints. Legacy fact tables are retained, inactive."""
from contextlib import contextmanager
import datetime as _dt
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import threading
import time
import uuid

DEFAULT_DAY_START_HOUR = 8
_CACHE_LOCK = threading.Lock()
_INITIALIZED_DBS: set[tuple[str, int, int]] = set()
_SOURCE_SKELETON_CACHE: dict[tuple[str, int, int, str, str, int], dict] = {}
_DONE_SUMMARY_CACHE: dict[tuple[str, int, int, str], tuple[str, str | None, int | None, str]] = {}


def _db_identity(db_path: Path):
    try:
        st = os.stat(db_path)
        if st.st_size > 0:
            return (str(db_path.resolve()), st.st_dev, st.st_ino)
    except OSError:
        pass
    return None


def read_day_start_hour(directory) -> int:
    try:
        raw = (Path(directory) / "runtime" / "day-boundary.json").read_text(encoding="utf-8")
        data = json.loads(raw)
        hour = data.get("day_start_hour")
        if type(hour) is int and 0 <= hour <= 23:
            return hour
    except Exception:
        pass
    return DEFAULT_DAY_START_HOUR


def logical_local_date(timestamp: float, day_start_hour: int = DEFAULT_DAY_START_HOUR) -> _dt.date:
    dt = _dt.datetime.fromtimestamp(float(timestamp))
    day = dt.date()
    if dt.hour < day_start_hour:
        day -= _dt.timedelta(days=1)
    return day


class Conflict(ValueError):
    pass


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class ContextStore:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        db_path = self.directory / "context.sqlite"
        existing_id = _db_identity(db_path)
        self.db = sqlite3.connect(db_path, timeout=10, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        with _CACHE_LOCK:
            needs_init = existing_id is None or existing_id not in _INITIALIZED_DBS
        if needs_init:
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS metadata (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
                INSERT OR IGNORE INTO metadata VALUES (1,0);
                CREATE TABLE IF NOT EXISTS sources (
                    id TEXT PRIMARY KEY, owner TEXT NOT NULL, generation INTEGER NOT NULL, version INTEGER NOT NULL,
                    revision TEXT NOT NULL, hash TEXT NOT NULL, deleted INTEGER NOT NULL,
                    text TEXT NOT NULL, payload TEXT NOT NULL, updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS analyses (
                    source_id TEXT PRIMARY KEY REFERENCES sources(id), source_revision TEXT NOT NULL,
                    summary TEXT NOT NULL, actions TEXT NOT NULL, updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS facts (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, basis TEXT NOT NULL,
                    forgotten INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS evidence (
                    fact_id TEXT NOT NULL REFERENCES facts(id), source_id TEXT NOT NULL REFERENCES sources(id),
                    source_revision TEXT NOT NULL, quote TEXT NOT NULL,
                    PRIMARY KEY(fact_id,source_id,source_revision));
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id), source_revision TEXT NOT NULL,
                    state TEXT NOT NULL, run_id TEXT, first_attempt REAL, replay_before REAL, error TEXT);
                CREATE TABLE IF NOT EXISTS memory_exclusions (source_id TEXT PRIMARY KEY REFERENCES sources(id));
                CREATE TABLE IF NOT EXISTS mutations (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, receipt TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS health_snapshots (
                    device_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload TEXT NOT NULL, synced_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS phone_source_snapshots (
                    device_id TEXT NOT NULL, kind TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL,
                    synced_at REAL NOT NULL, PRIMARY KEY(device_id,kind));
            """)
            if "input" not in {row[1] for row in self.db.execute("PRAGMA table_info(jobs)")}:
                self.db.execute("ALTER TABLE jobs ADD COLUMN input TEXT")
            if "result" not in {row[1] for row in self.db.execute("PRAGMA table_info(jobs)")}:
                self.db.execute("ALTER TABLE jobs ADD COLUMN result TEXT")
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS memory_reviews (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, input TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending', run_id TEXT, first_attempt REAL,
                    replay_before REAL, error TEXT, result TEXT, finished REAL);
                CREATE TABLE IF NOT EXISTS memory_review_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS recording_summaries (
                    id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, input TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending', parts TEXT NOT NULL, outputs TEXT NOT NULL DEFAULT '[]',
                    stage INTEGER NOT NULL DEFAULT 0, part INTEGER NOT NULL DEFAULT 0,
                    attempt INTEGER NOT NULL DEFAULT 0, run_id TEXT, first_attempt REAL, replay_before REAL,
                    error TEXT, result TEXT, finished REAL);
                CREATE INDEX IF NOT EXISTS jobs_source ON jobs(source_id, source_revision);
                CREATE INDEX IF NOT EXISTS jobs_state ON jobs(state);
                CREATE INDEX IF NOT EXISTS recording_summaries_state ON recording_summaries(state, id, fingerprint);
            """)
            for table in ('jobs', 'memory_reviews'):
                if 'attempt' not in {row[1] for row in self.db.execute(f'PRAGMA table_info({table})')}:
                    self.db.execute(f'ALTER TABLE {table} ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0')
            initialized_id = _db_identity(db_path)
            if initialized_id is not None:
                with _CACHE_LOCK:
                    if len(_INITIALIZED_DBS) >= 256:
                        _INITIALIZED_DBS.clear()
                    _INITIALIZED_DBS.add(initialized_id)
        self._db_id = _db_identity(db_path)

    def close(self):
        self.db.close()

    @contextmanager
    def write(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    @property
    def revision(self):
        return self.db.execute("SELECT revision FROM metadata WHERE id=1").fetchone()[0]

    def advance(self):
        self.db.execute("UPDATE metadata SET revision=revision+1 WHERE id=1")
        return self.revision

    def sync_source(self, payload):
        for key in ("library_id", "session_id", "device_id"):
            uuid.UUID(payload[key])
        source_id = payload["library_id"].lower() + "/" + payload["session_id"].lower()
        generation, version = payload["generation"], payload["version"]
        if type(generation) is not int or type(version) is not int or min(generation, version) < 0:
            raise ValueError("Invalid source generation/version")
        if type(payload["deleted"]) is not bool:
            raise ValueError("deleted must be boolean")
        pending_ranges = payload.get('pending_transcription_ranges', [])
        if not isinstance(pending_ranges, list) or len(pending_ranges) > 50_000:
            raise ValueError('Invalid pending transcription ranges')
        for pending in pending_ranges:
            if (not isinstance(pending, dict) or set(pending) != {'start', 'end'}
                    or any(type(pending[key]) not in (int, float) or not math.isfinite(pending[key]) for key in ('start', 'end'))
                    or pending['end'] <= pending['start']):
                raise ValueError('Invalid pending transcription interval')
        if payload['deleted'] and pending_ranges:
            raise ValueError('Deleted sources cannot have pending transcription')
        deleted = payload["deleted"]
        spans = payload["spans"]
        if not isinstance(spans, list) or len(spans) > 50_000:
            raise ValueError("Too many spans; split the recording explicitly")
        seen = set()
        for span in spans:
            uuid.UUID(span["id"])
            if span["id"] in seen or not isinstance(span["text"], str):
                raise ValueError("Invalid or duplicate transcript span")
            seen.add(span["id"])
            if type(span["recorded_at"]) not in (int, float) or not math.isfinite(span["recorded_at"]):
                raise ValueError("Missing source time")
            if "is_owner" in span and span["is_owner"] is not None and type(span["is_owner"]) is not bool:
                raise ValueError("Invalid span is_owner flag")
        text = "\n".join(span["text"] for span in spans)
        if deleted and spans or len(text.encode()) > 4_000_000:
            raise ValueError("Deleted sources must be empty; source size limit is 4 MB, never truncated")
        if payload["text_sha256"] != digest(text):
            raise ValueError("Transcript checksum mismatch")
        revision = f"{generation}:{version}:{digest(text)}:{int(deleted)}"
        def _core_payload(doc: dict) -> dict:
            out = dict(doc)
            out.pop('pending_transcription_ranges', None)
            if isinstance(out.get("spans"), list):
                out["spans"] = [
                    {k: v for k, v in s.items() if k != "is_owner"} if isinstance(s, dict) else s
                    for s in out["spans"]
                ]
            return out
        with self.write():
            previous = self.db.execute("SELECT * FROM sources WHERE id=?", (source_id,)).fetchone()
            if previous:
                if previous["owner"] != payload["device_id"]:
                    raise Conflict("Source belongs to another device")
                if previous["revision"] == revision:
                    prev_payload = json.loads(previous["payload"])
                    if prev_payload != payload:
                        if _core_payload(prev_payload) != _core_payload(payload):
                            raise Conflict("Source metadata differs at the same revision")
                        self.db.execute("UPDATE sources SET payload=? WHERE id=?", (canonical(payload), source_id))
                        self.advance()
                    return {"source_id": source_id, "source_revision": revision, "revision": self.revision}
                if previous["deleted"] or (generation, version) <= (previous["generation"], previous["version"]):
                    raise Conflict("Source revision is stale or deleted")
            self.db.execute("""INSERT INTO sources VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET generation=excluded.generation,version=excluded.version,
                revision=excluded.revision,hash=excluded.hash,deleted=excluded.deleted,text=excluded.text,
                payload=excluded.payload,updated=excluded.updated""",
                (source_id, payload["device_id"], generation, version, revision, digest(text), int(deleted), text,
                 canonical(payload), time.time()))
            # An admitted run stays visible until reconciled, so a fresh source cannot start a second writer.
            self.db.execute("UPDATE jobs SET state='superseded' WHERE source_id=? AND state NOT IN ('done','superseded','running') AND first_attempt IS NULL", (source_id,))
            excluded = self.db.execute("SELECT 1 FROM memory_exclusions WHERE source_id=?", (source_id,)).fetchone()
            if not deleted and text.strip() and not excluded:
                job = str(uuid.uuid5(uuid.NAMESPACE_URL, source_id + ":" + revision))
                self.db.execute("INSERT INTO jobs(id,source_id,source_revision,state) VALUES(?,?,?,'pending')",
                                (job, source_id, revision))
            if deleted:
                self.db.execute("DELETE FROM analyses WHERE source_id=?", (source_id,))
                self.db.execute("DELETE FROM evidence WHERE source_id=?", (source_id,))
            current = self.advance()
            return {"source_id": source_id, "source_revision": revision, "revision": current}

    def source(self, source_id, expected_revision=None):
        row = self.db.execute("SELECT * FROM sources WHERE id=? AND deleted=0", (source_id,)).fetchone()
        if not row:
            raise Conflict("Source is missing or deleted")
        if expected_revision and row["revision"] != expected_revision:
            raise Conflict("Source changed; read the current version before continuing")
        return row

    def build_windows(self, source_id, source_revision, payload, excluded, done_by_fp, done_by_window, active_fps, summarize=False, cutoff=0.0):
        spans = payload.get("spans") or []
        if not spans:
            return []
        library_id = str(uuid.UUID(payload["library_id"]))
        day_start_hour = read_day_start_hour(self.directory)
        groups, position = [], 0
        for span in spans:
            text = span["text"]
            start = float(span["recorded_at"])
            end_pos = position + len(text)
            day = logical_local_date(start, day_start_hour)
            est_end = start + min(60.0, len(text) * 0.22)
            if groups and day == groups[-1]["day"] and start - groups[-1]["est_end"] <= 300:
                groups[-1]["end_at"] = max(groups[-1]["end_at"], start)
                groups[-1]["est_end"] = max(groups[-1]["est_end"], est_end)
                groups[-1]["end"] = end_pos
                groups[-1]["spans"].append(span)
            else:
                groups.append({"day": day, "recorded_at": start, "end_at": start, "est_end": est_end,
                               "offset": position, "end": end_pos, "spans": [span]})
            position = end_pos + 1
        windows = []
        for g in groups:
            w_spans = g["spans"]
            w_text = "\n\n".join(s["text"] for s in w_spans)
            fp = digest(w_text)
            w_summary = None
            if not excluded:
                w_summary = done_by_fp.get(fp)
                if w_summary is None:
                    for w_start, res in done_by_window.get(library_id, ()):
                        if g["recorded_at"] - 300 <= w_start <= g["end_at"] + 60:
                            w_summary = res
                            break
                if w_summary is None and summarize and g["recorded_at"] >= cutoff and fp not in active_fps and sum(1 for c in w_text if c.isalnum()) >= 20 and len(w_text.encode()) <= 2_000_000:
                    import datetime as _dt, recording_summary
                    tz_offset = int(_dt.datetime.fromtimestamp(g["recorded_at"]).astimezone().utcoffset().total_seconds())
                    win_key = f"{int(g['recorded_at'])}-{tz_offset}"
                    try:
                        recording_summary.enqueue(self, {"library_id": library_id, "window_id": win_key, "revision": fp, "text": w_text})
                        active_fps.add(fp)
                    except Exception:
                        pass
            preview = "  ".join(s["text"] for s in w_spans)[:256].replace("\n", " ")
            windows.append({
                "id": f"{source_id}#{w_spans[0]['id']}",
                "source_id": source_id,
                "source_revision": source_revision,
                "recorded_at": g["recorded_at"],
                "end_at": g["end_at"],
                "offset": g["offset"],
                "end": g["end"],
                "total_characters": g["end"] - g["offset"],
                "preview": preview,
                "summary": w_summary,
            })
        return windows

    @staticmethod
    def _build_source_skeleton(source_id, total_characters, preview, payload, day_start_hour):
        spans = payload.get("spans") or []
        recorded_at = payload.get("recorded_at")
        if not spans:
            return {
                "recorded_at": recorded_at,
                "total_characters": int(total_characters),
                "preview": preview,
                "library_id": None,
                "latest_span_at": 0.0,
                "windows": (),
            }
        library_id = str(uuid.UUID(payload["library_id"]))
        groups, position = [], 0
        latest_span_at = 0.0
        for idx, span in enumerate(spans):
            text = span["text"]
            start = float(span["recorded_at"])
            if start > latest_span_at:
                latest_span_at = start
            end_pos = position + len(text)
            day = logical_local_date(start, day_start_hour)
            est_end = start + min(60.0, len(text) * 0.22)
            if groups and day == groups[-1]["day"] and start - groups[-1]["est_end"] <= 300:
                groups[-1]["end_at"] = max(groups[-1]["end_at"], start)
                groups[-1]["est_end"] = max(groups[-1]["est_end"], est_end)
                groups[-1]["end"] = end_pos
                groups[-1]["span_end_idx"] = idx + 1
                groups[-1]["texts"].append(text)
            else:
                groups.append({
                    "day": day,
                    "recorded_at": start,
                    "end_at": start,
                    "est_end": est_end,
                    "offset": position,
                    "end": end_pos,
                    "first_span_id": span["id"],
                    "span_start_idx": idx,
                    "span_end_idx": idx + 1,
                    "texts": [text],
                })
            position = end_pos + 1
        win_skeletons = []
        for g in groups:
            texts = g["texts"]
            w_text = "\n\n".join(texts)
            fp = digest(w_text)
            can_enqueue = sum(1 for c in w_text if c.isalnum()) >= 20 and len(w_text.encode()) <= 2_000_000
            w_preview = "  ".join(texts)[:256].replace("\n", " ")
            win_skeletons.append({
                "id": f"{source_id}#{g['first_span_id']}",
                "recorded_at": g["recorded_at"],
                "end_at": g["end_at"],
                "offset": g["offset"],
                "end": g["end"],
                "total_characters": g["end"] - g["offset"],
                "preview": w_preview,
                "fp": fp,
                "can_enqueue": can_enqueue,
                "span_start_idx": g["span_start_idx"],
                "span_end_idx": g["span_end_idx"],
            })
        return {
            "recorded_at": recorded_at,
            "total_characters": int(total_characters),
            "preview": preview,
            "library_id": library_id,
            "latest_span_at": latest_span_at,
            "windows": tuple(win_skeletons),
        }

    def _load_summary_index(self):
        srows = self.db.execute(
            "SELECT id, fingerprint, state FROM recording_summaries WHERE state IN ('done','pending','running')"
        ).fetchall()
        active_fps = {r["fingerprint"] for r in srows}
        done_ids = [r["id"] for r in srows if r["state"] == "done"]
        if not done_ids:
            return {}, {}, active_fps
        db_id = self._db_id
        cached_entries = {}
        missing_ids = []
        if db_id is not None:
            with _CACHE_LOCK:
                for sid in done_ids:
                    entry = _DONE_SUMMARY_CACHE.get((*db_id, sid))
                    if entry is not None:
                        cached_entries[sid] = entry
                    else:
                        missing_ids.append(sid)
        else:
            missing_ids = done_ids
        if missing_ids:
            fetched_entries = {}
            for batch_start in range(0, len(missing_ids), 400):
                chunk_ids = missing_ids[batch_start:batch_start + 400]
                placeholders = ",".join("?" for _ in chunk_ids)
                for drow in self.db.execute(
                    f"SELECT id, fingerprint, input, result FROM recording_summaries WHERE id IN ({placeholders})",
                    chunk_ids,
                ).fetchall():
                    res = drow["result"]
                    lib, w_start = None, None
                    if res:
                        try:
                            info = json.loads(drow["input"])
                            lib = str(uuid.UUID(info["library_id"]))
                            w_start = int(info["window_id"].rsplit("-", 1)[0])
                        except Exception:
                            lib, w_start = None, None
                    fetched_entries[drow["id"]] = (drow["fingerprint"], lib, w_start, res or "")
            if db_id is not None and fetched_entries:
                with _CACHE_LOCK:
                    if len(_DONE_SUMMARY_CACHE) >= 8_192:
                        _DONE_SUMMARY_CACHE.clear()
                    for sid, entry in fetched_entries.items():
                        _DONE_SUMMARY_CACHE[(*db_id, sid)] = entry
            cached_entries.update(fetched_entries)
        done_by_fp, done_by_window = {}, {}
        for sid in done_ids:
            entry = cached_entries.get(sid)
            if not entry:
                continue
            fp, lib, w_start, res = entry
            if res:
                done_by_fp[fp] = res
                if lib is not None and w_start is not None:
                    done_by_window.setdefault(lib, []).append((w_start, res))
        return done_by_fp, done_by_window, active_fps

    def list_sources(self, after="", limit=50, summarize=False, include_organization=True):
        if not 1 <= limit <= 200:
            raise ValueError("limit must be 1...200")
        header_rows = self.db.execute(
            "SELECT id, revision, hash FROM sources WHERE deleted=0 AND id>? ORDER BY id LIMIT ?",
            (after, limit + 1),
        ).fetchall()
        page_rows = header_rows[:limit]
        if not page_rows:
            return {"revision": self.revision, "items": [], "next_cursor": None}

        day_start_hour = read_day_start_hour(self.directory)
        db_id = self._db_id
        skeletons = {}
        missing_source_ids = []
        if db_id is not None:
            with _CACHE_LOCK:
                for hrow in page_rows:
                    sid, rev = hrow["id"], hrow["revision"]
                    cached = _SOURCE_SKELETON_CACHE.get((*db_id, sid, rev, day_start_hour))
                    if cached is not None:
                        skeletons[(sid, rev)] = cached
                    else:
                        missing_source_ids.append(sid)
        else:
            missing_source_ids = [hrow["id"] for hrow in page_rows]

        loaded_payloads = {}
        if missing_source_ids:
            placeholders = ",".join("?" for _ in missing_source_ids)
            full_rows = {
                r["id"]: r
                for r in self.db.execute(
                    f"SELECT id, revision, LENGTH(text) AS total_characters, SUBSTR(text,1,256) AS preview, payload FROM sources WHERE id IN ({placeholders})",
                    missing_source_ids,
                ).fetchall()
            }
            built = {}
            for hrow in page_rows:
                sid, rev = hrow["id"], hrow["revision"]
                if (sid, rev) in skeletons:
                    continue
                frow = full_rows.get(sid)
                if frow is None or frow["revision"] != rev:
                    frow = self.db.execute(
                        "SELECT id, revision, LENGTH(text) AS total_characters, SUBSTR(text,1,256) AS preview, payload FROM sources WHERE id=?",
                        (sid,),
                    ).fetchone()
                if frow is None:
                    continue
                payload = json.loads(frow["payload"])
                loaded_payloads[sid] = payload
                skel = self._build_source_skeleton(sid, frow["total_characters"], frow["preview"], payload, day_start_hour)
                skeletons[(sid, frow["revision"])] = skel
                built[(sid, frow["revision"])] = skel
            if db_id is not None and built:
                with _CACHE_LOCK:
                    if len(_SOURCE_SKELETON_CACHE) >= 1_024:
                        _SOURCE_SKELETON_CACHE.clear()
                    for (sid, rev), skel in built.items():
                        _SOURCE_SKELETON_CACHE[(*db_id, sid, rev, day_start_hour)] = skel

        done_by_fp, done_by_window, active_fps = self._load_summary_index()
        page_ids = [hrow["id"] for hrow in page_rows]
        id_placeholders = ",".join("?" for _ in page_ids)
        excluded_ids = {
            r[0]
            for r in self.db.execute(
                f"SELECT source_id FROM memory_exclusions WHERE source_id IN ({id_placeholders})",
                page_ids,
            ).fetchall()
        }
        analyses_map = {
            (r["source_id"], r["source_revision"]): (r["summary"], json.loads(r["actions"]))
            for r in self.db.execute(
                f"SELECT source_id, source_revision, summary, actions FROM analyses WHERE source_id IN ({id_placeholders})",
                page_ids,
            ).fetchall()
        }

        latest = max((skel["latest_span_at"] for skel in skeletons.values()), default=0.0)
        cutoff = latest - 172_800
        items = []
        for hrow in page_rows:
            sid, rev = hrow["id"], hrow["revision"]
            skel = skeletons.get((sid, rev))
            if skel is None:
                continue
            excluded = sid in excluded_ids
            library_id = skel["library_id"]
            windows = []
            for w in skel["windows"]:
                fp = w["fp"]
                w_summary = None
                if not excluded:
                    w_summary = done_by_fp.get(fp)
                    if w_summary is None and library_id is not None:
                        for w_start, res in done_by_window.get(library_id, ()):
                            if w["recorded_at"] - 300 <= w_start <= w["end_at"] + 60:
                                w_summary = res
                                break
                    if (
                        w_summary is None
                        and summarize
                        and w["can_enqueue"]
                        and w["recorded_at"] >= cutoff
                        and fp not in active_fps
                        and library_id is not None
                    ):
                        import recording_summary
                        payload = loaded_payloads.get(sid)
                        if payload is None:
                            prow = self.db.execute("SELECT payload FROM sources WHERE id=?", (sid,)).fetchone()
                            payload = json.loads(prow["payload"]) if prow else {}
                            loaded_payloads[sid] = payload
                        w_spans = (payload.get("spans") or [])[w["span_start_idx"]:w["span_end_idx"]]
                        w_text = "\n\n".join(s["text"] for s in w_spans)
                        tz_offset = int(_dt.datetime.fromtimestamp(w["recorded_at"]).astimezone().utcoffset().total_seconds())
                        win_key = f"{int(w['recorded_at'])}-{tz_offset}"
                        try:
                            recording_summary.enqueue(
                                self,
                                {"library_id": library_id, "window_id": win_key, "revision": fp, "text": w_text},
                            )
                            active_fps.add(fp)
                        except Exception:
                            pass
                windows.append({
                    "id": w["id"],
                    "source_id": sid,
                    "source_revision": rev,
                    "recorded_at": w["recorded_at"],
                    "end_at": w["end_at"],
                    "offset": w["offset"],
                    "end": w["end"],
                    "total_characters": w["total_characters"],
                    "preview": w["preview"],
                    "summary": w_summary,
                })
            recorded_summary = next((w["summary"] for w in reversed(windows) if w["summary"]), None) if not excluded else None
            analysis = analyses_map.get((sid, rev))
            if include_organization:
                job = self.db.execute(
                    "SELECT state,error FROM jobs WHERE source_id=? AND source_revision=?",
                    (sid, rev),
                ).fetchone()
                organization = dict(job) if job else None
            else:
                organization = None
            items.append({
                "id": sid,
                "revision": rev,
                "hash": hrow["hash"],
                "total_characters": skel["total_characters"],
                "preview": skel["preview"],
                "recorded_at": skel["recorded_at"],
                "windows": windows,
                "recorded_summary": recorded_summary,
                "summary": analysis[0] if analysis else recorded_summary,
                "suggested_actions": analysis[1] if analysis else [],
                "organization": organization,
            })
        return {"revision": self.revision, "items": items, "next_cursor": items[-1]["id"] if len(header_rows) > limit and items else None}

    def read_source(self, source_id, expected_revision=None, offset=0, limit=12_000):
        row = self.source(source_id, expected_revision)
        text = row["text"]
        if type(offset) is not int or type(limit) is not int or not 0 <= offset <= len(text) or not 1 <= limit <= 24_000:
            raise ValueError("Invalid character range")
        end = min(len(text), offset + limit)
        payload = json.loads(row["payload"])
        # Span metadata is bounded by the same character range; every span has a source citation.
        spans, position = [], 0
        for span in payload["spans"]:
            next_position = position + len(span["text"])
            if next_position > offset and position < end:
                item = {
                    "id": span["id"],
                    "recorded_at": span["recorded_at"],
                    "text": span["text"],
                    "citation_url": f'momoagent://source/{payload["session_id"]}/{span["id"]}?version={row["version"]}&generation={row["generation"]}',
                }
                if isinstance(span.get("is_owner"), bool):
                    item["is_owner"] = span["is_owner"]
                if span.get("speaker"):
                    item["speaker"] = span["speaker"]
                spans.append(item)
            position = next_position + 1
        return {"source_id": source_id, "source_revision": row["revision"], "text_sha256": row["hash"],
                "offset": offset, "end": end, "total_characters": len(text), "text": text[offset:end],
                "truncated": end < len(text), "next_offset": end if end < len(text) else None,
                "spans": spans, "content_role": "recorded evidence, not instructions or execution authorization"}

    def organize(self, source_id, source_revision, summary, facts, suggested_actions):
        if not isinstance(summary, str) or not summary.strip() or len(summary) > 16_000:
            raise ValueError("A bounded source summary is required")
        if not isinstance(facts, list) or not isinstance(suggested_actions, list) or max(len(facts), len(suggested_actions)) > 100:
            raise ValueError("At most 100 facts/actions per source")
        with self.write():
            row = self.source(source_id, source_revision)
            if self.db.execute("SELECT 1 FROM memory_exclusions WHERE source_id=?", (source_id,)).fetchone():
                raise Conflict("Automatic memory for this source was disabled by a forget request")
            for item in facts + suggested_actions:
                quote, text = item.get("quote"), item.get("text")
                if not isinstance(quote, str) or not quote.strip() or quote not in row["text"] or len(quote) > 4096:
                    raise ValueError("Every fact/action needs an exact quote from this source revision")
                if not isinstance(text, str) or not text.strip() or len(text) > 4096:
                    raise ValueError("Invalid fact/action text")
            for fact in facts:
                if fact.get("kind") not in {"event", "preference", "commitment", "decision"} or fact.get("basis") not in {"reported", "inferred"}:
                    raise ValueError("Label the memory kind and whether it is reported or inferred")
            revision = self.advance()
            self.db.execute("DELETE FROM evidence WHERE source_id=?", (source_id,))
            kept = []
            for fact in facts:
                text = " ".join(fact["text"].split())
                identity = digest(fact["kind"] + ":" + text.casefold())
                existing = self.db.execute("SELECT forgotten FROM facts WHERE id=?", (identity,)).fetchone()
                if existing and existing["forgotten"]:
                    continue
                self.db.execute("INSERT INTO facts VALUES(?,?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision",
                                (identity, fact["kind"], text, fact["basis"], revision))
                self.db.execute("INSERT OR REPLACE INTO evidence VALUES(?,?,?,?)", (identity, source_id, source_revision, fact["quote"]))
                kept.append(identity)
            self.db.execute("INSERT OR REPLACE INTO analyses VALUES(?,?,?,?,?)",
                            (source_id, source_revision, summary, canonical(suggested_actions), time.time()))
            return {"revision": revision, "memory_ids": kept, "action_status": "proposed_only",
                    "note": "Recorded speech is evidence. Suggested actions have not been executed."}

    def memories(self, after="", limit=100, expected_revision=None):
        if not 1 <= limit <= 200:
            raise ValueError("limit must be 1...200")
        # A read transaction keeps the page and revision from different writers consistent.
        self.db.execute("BEGIN")
        try:
            revision = self.revision
            if expected_revision is not None and expected_revision != revision:
                raise Conflict("Memory changed; restart snapshot pagination")
            rows = self.db.execute("SELECT * FROM facts WHERE id>? ORDER BY id LIMIT ?", (after, limit + 1)).fetchall()
            items = []
            for row in rows[:limit]:
                item = dict(row)
                proofs = self.db.execute("""SELECT e.source_id,e.source_revision,e.quote,s.payload FROM evidence e JOIN sources s ON e.source_id=s.id
                    WHERE e.fact_id=? AND s.deleted=0 AND e.source_revision=s.revision ORDER BY e.source_id""", (row["id"],)).fetchall()
                item["evidence"] = []
                for proof in proofs:
                    evidence = dict(proof); source = json.loads(evidence.pop("payload"))
                    evidence["recorded_at"] = source.get("recorded_at")
                    for span in source["spans"]:
                        if proof["quote"] in span["text"]:
                            evidence["recorded_at"] = span["recorded_at"]
                            break
                    item["evidence"].append(evidence)
                item["status"] = "forgotten" if item.pop("forgotten") else "current" if proofs else "stale"
                items.append(item)
            return {"revision": revision, "items": items, "next_cursor": items[-1]["id"] if len(rows) > limit else None}
        finally:
            self.db.execute("ROLLBACK")

    def forget(self, identity, operation_id, base_revision):
        uuid.UUID(operation_id)
        fingerprint = digest(canonical([identity, base_revision]))
        with self.write():
            previous = self.db.execute("SELECT * FROM mutations WHERE id=?", (operation_id,)).fetchone()
            if previous:
                if previous["fingerprint"] != fingerprint:
                    raise Conflict("Mutation identity was reused for different content")
                return json.loads(previous["receipt"])
            row = self.db.execute("SELECT * FROM facts WHERE id=?", (identity,)).fetchone()
            if not row or row["revision"] != base_revision:
                raise Conflict("Memory changed; refresh before forgetting")
            revision = self.advance()
            # Keep only the hash tombstone to stop future consolidation resurrecting the fact.
            self.db.execute("UPDATE facts SET text='',forgotten=1,revision=? WHERE id=?", (revision, identity))
            self.db.execute("INSERT OR IGNORE INTO memory_exclusions SELECT source_id FROM evidence WHERE fact_id=?", (identity,))
            self.db.execute("DELETE FROM analyses WHERE source_id IN (SELECT source_id FROM evidence WHERE fact_id=?)", (identity,))
            self.db.execute("UPDATE jobs SET state='suppressed' WHERE source_id IN (SELECT source_id FROM evidence WHERE fact_id=?)", (identity,))
            self.db.execute("DELETE FROM evidence WHERE fact_id=?", (identity,))
            result = {"id": identity, "revision": revision, "status": "forgotten"}
            self.db.execute("INSERT INTO mutations VALUES(?,?,?)", (operation_id, fingerprint, canonical(result)))
            return result

    def write_result(self, source_id, source_revision, title, text):
        if not isinstance(title, str) or not 1 <= len(title) <= 200 or not isinstance(text, str) or not 1 <= len(text) <= 100_000:
            raise ValueError("Invalid result")
        with self.write():
            self.source(source_id, source_revision)
            identity = digest(canonical([source_id, source_revision, title, text]))
            directory = self.directory / "results"; directory.mkdir(exist_ok=True)
            file = directory / (identity + ".md")
            content = f"# {title}\n\n{text}\n\n来源：{source_id}\n修订：{source_revision}\n"
            temporary = directory / (identity + ".tmp")
            temporary.write_text(content, encoding="utf-8"); temporary.replace(file)
            return {"artifact_id": identity, "path": str(file), "sha256": digest(content), "source_revision": source_revision}
