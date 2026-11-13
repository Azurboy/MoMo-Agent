"""Mac-owned watch audio, durable delivery receipts, and the local speech queue."""

import asyncio
import base64
from contextlib import contextmanager
from datetime import datetime
import fcntl
import hashlib
import json
import logging
import math
import os
from pathlib import Path
import re
import sqlite3
import struct
import subprocess
import tempfile
import time
import uuid
import wave
from xml.etree import ElementTree

MAX_AUDIO_BYTES = 8_000_000
MAX_FRAMES = 4_800_000  # Maximum five-minute watch segment, at 16 kHz.
EXTENSIONS = {"aac": ".m4a", "pcmInt16": ".wav", "pcmFloat32": ".wav"}
LOG = logging.getLogger(__name__)


class RecordingConflict(ValueError):
    """An existing upload identity has different immutable contents."""


def _uuid(value):
    try:
        canonical = str(uuid.UUID(str(value)))
        if canonical != str(value).lower():
            raise ValueError()
        return canonical
    except (ValueError, TypeError, AttributeError) as exc:
        raise ValueError("无效的录音标识。") from exc


def _date(value):
    if not isinstance(value, str) or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})", value):
        raise ValueError("录音缺少有效的采集时间。")
    date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return date.timestamp()


def _integer(value, minimum, maximum):
    return type(value) is int and minimum <= value <= maximum


def _manifest(raw, device_id, ident, audio):
    if not 0 < len(raw) <= 16384 or not 0 < len(audio) <= MAX_AUDIO_BYTES:
        raise ValueError("录音文件或清单大小无效。")
    try:
        m = json.loads(raw)
        if not isinstance(m, dict) or not isinstance(m["frames"], dict):
            raise ValueError("无效的录音清单。")
        if (_uuid(m["sourceDeviceID"]) != device_id or _uuid(m["chunkID"]) != ident or
                m["sourceKind"] != "watch" or m["representation"] != "full"):
            raise ValueError("录音来源和配对设备不一致。")
        _uuid(m["sessionID"])
        _uuid(m["epochID"])
        start, count = m["frames"]["start"], m["frames"]["count"]
        if (not _integer(m["manifestVersion"], 1, 1) or
                not isinstance(m["sourceBuild"], str) or not 0 < len(m["sourceBuild"].encode()) <= 256 or
                not _integer(m["sequence"], 0, 2**63 - 1) or not _integer(count, 1, MAX_FRAMES) or
                not _integer(start, 0, 2**63 - 1 - count) or m["sourceRanges"] != [m["frames"]] or
                not _integer(m["channels"], 1, 1) or m["sampleRate"] != 16000 or m["timebaseHz"] != 16000 or
                not _integer(m["timezoneOffset"], -50400, 50400) or m["codec"] not in EXTENSIONS or
                not _integer(m["decodedFrameCount"], 1, MAX_FRAMES + 8192) or
                not _integer(m["primingFrames"], 0, 8192) or not _integer(m["paddingFrames"], 0, 8192) or
                m["decodedFrameCount"] - m["primingFrames"] - m["paddingFrames"] != count):
            raise ValueError("采集格式或采样范围无效。")
        if not _integer(m["byteCount"], len(audio), len(audio)) or hashlib.sha256(audio).hexdigest() != m["audioSHA256"]:
            raise ValueError("录音文件校验失败。")
        _date(m["sealedAt"])
        recorded = _date(m["wallClockAnchor"]) + start / 16000
        if not -62135596800 <= recorded < 253402300800 - count / 16000:
            raise ValueError("录音时间超出支持范围。")
        return m, recorded
    except (KeyError, TypeError, OverflowError, RecursionError, UnicodeError) as exc:
        raise ValueError("无法读取录音清单。") from exc


def _validate_audio(path, manifest):
    """Decode the entire container before authorizing removal of the watch copy."""
    ns = "{http://apple.com/core_audio/audio_info}"
    try:
        info = subprocess.run(["/usr/bin/afinfo", "-x", path], capture_output=True, timeout=15, check=True)
        root = ElementTree.fromstring(info.stdout)
        tracks = root.findall(f".//{ns}track")
        if len(tracks) != 1:
            raise ValueError("录音必须只有一条音轨。")
        track = tracks[0]
        codec = manifest["codec"]
        file_type = root.findtext(f".//{ns}file_type", "").strip(" '")
        if (file_type not in (("mp4f", "m4af") if codec == "aac" else ("WAVE",)) or
                track.findtext(f"{ns}format_type", "").strip() != ("aac" if codec == "aac" else "lpcm") or
                float(track.findtext(f"{ns}sample_rate", "0")) != 16000 or
                int(track.findtext(f"{ns}num_channels", "0")) != 1):
            raise ValueError("录音的编码、声道或采样率与清单不一致。")
        if codec != "aac":
            bits = int(track.findtext(f"{ns}bit_depth", "0"))
            flags = int(track.findtext(f"{ns}format_flags", "0"), 16)
            if bits != (16 if codec == "pcmInt16" else 32) or bool(flags & 1) != (codec == "pcmFloat32"):
                raise ValueError("PCM 格式与清单不一致。")
        # Reject implausible duration before asking the native decoder to expand it.
        duration = float(track.findtext(f"{ns}duration", "nan"))
        if not math.isfinite(duration) or not 0 < duration <= (MAX_FRAMES + 8192) / 16000 + .01:
            raise ValueError("录音时长无效。")
        with tempfile.TemporaryDirectory(dir=path.parent) as scratch:
            decoded = Path(scratch) / "verified.wav"
            subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16", path, decoded],
                           capture_output=True, timeout=30, check=True)
            with wave.open(str(decoded), "rb") as pcm:
                frames = pcm.getnframes()
                if (pcm.getnchannels() != 1 or pcm.getframerate() != 16000 or
                        frames != manifest["decodedFrameCount"] or len(pcm.readframes(frames)) != frames * 2):
                    raise ValueError("录音解码长度与清单不一致。")
    except (subprocess.SubprocessError, ElementTree.ParseError, wave.Error, EOFError, struct.error) as exc:
        raise ValueError("无法完整解码录音。") from exc


class RecordingArchive:
    def __init__(self, directory, receiver_id, library_id):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.receiver_id, self.library_id = _uuid(receiver_id), _uuid(library_id)
        self.database = self.directory / "recordings.sqlite3"
        with self._connection() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS identity(receiver_id TEXT, library_id TEXT);
                CREATE TABLE IF NOT EXISTS chunks(
                    id TEXT PRIMARY KEY, device TEXT NOT NULL, session TEXT NOT NULL, epoch TEXT NOT NULL,
                    sequence INTEGER NOT NULL, manifest BLOB NOT NULL, filename TEXT NOT NULL, receipt TEXT NOT NULL,
                    recorded_at REAL NOT NULL, duration REAL NOT NULL, state TEXT NOT NULL DEFAULT 'queued',
                    transcript TEXT NOT NULL DEFAULT '', spans TEXT NOT NULL DEFAULT '[]',
                    published INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0,
                    retry_at REAL NOT NULL DEFAULT 0, UNIQUE(device,epoch,sequence)
                );
                CREATE INDEX IF NOT EXISTS chunks_time ON chunks(recorded_at DESC,id DESC);
                CREATE INDEX IF NOT EXISTS chunks_queue ON chunks(state,retry_at);
                CREATE INDEX IF NOT EXISTS chunks_session ON chunks(session,device);
                CREATE INDEX IF NOT EXISTS chunks_epoch_frames ON chunks(epoch,json_extract(CAST(manifest AS TEXT),'$.frames.start'));
            """)
            db.execute("BEGIN IMMEDIATE")
            identity = db.execute("SELECT * FROM identity").fetchone()
            if identity is None:
                db.execute("INSERT INTO identity VALUES(?,?)", (self.receiver_id, self.library_id))
            elif tuple(identity) != (self.receiver_id, self.library_id):
                raise RecordingConflict("此归档已绑定另一台 Mac 或资料库。")
        self.database.chmod(0o600)

    @contextmanager
    def _connection(self):
        db = sqlite3.connect(self.database, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA synchronous=FULL")
            db.execute("PRAGMA fullfsync=ON")
            with db:
                yield db
        finally:
            db.close()

    def close(self):
        """Operations use short-lived SQLite connections. The caller cancels run_worker separately."""

    def receive(self, device_id, chunk_id, manifest_bytes, audio_bytes):
        device, ident = _uuid(device_id), _uuid(chunk_id)
        m, recorded = _manifest(manifest_bytes, device, ident, audio_bytes)
        session, epoch = _uuid(m["sessionID"]), _uuid(m["epochID"])
        manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
        path = self.directory / (ident + EXTENSIONS[m["codec"]])
        with self._connection() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT receipt,manifest FROM chunks WHERE id=?", (ident,)).fetchone()
            if old is not None:
                if old["manifest"] != manifest_bytes:
                    raise RecordingConflict("此录音标识已对应另一份原音。")
                receipt = json.loads(old["receipt"])
                if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == m["audioSHA256"]:
                    return receipt
            else:
                same_seq = db.execute("SELECT 1 FROM chunks WHERE device=? AND epoch=? AND sequence=?",
                                      (device, epoch, m["sequence"])).fetchone()
                if same_seq:
                    raise RecordingConflict("同一录音序号已对应另一段原音。")
                wrong_capture = db.execute("""SELECT 1 FROM chunks WHERE session=? AND device!=?
                                              UNION ALL SELECT 1 FROM chunks WHERE epoch=? AND session!=? LIMIT 1""",
                                           (session, device, epoch, session)).fetchone()
                if wrong_capture:
                    raise RecordingConflict("录音批次与此前收到的采集设备不一致。")
                start = m["frames"]["start"]
                # With disjoint stored ranges, the last range starting before this chunk ends is sufficient.
                previous = db.execute("""SELECT manifest FROM chunks WHERE epoch=? AND json_extract(CAST(manifest AS TEXT),'$.frames.start') < ?
                                         ORDER BY json_extract(CAST(manifest AS TEXT),'$.frames.start') DESC LIMIT 1""",
                                      (epoch, start + m["frames"]["count"])).fetchone()
                if previous:
                    frames = json.loads(previous["manifest"])["frames"]
                    if frames["start"] + frames["count"] > start:
                        raise RecordingConflict("同一采集时段已对应另一段原音。")
                receipt = {"messageID": str(uuid.uuid4()), "receiptID": str(uuid.uuid4()),
                           "receiverDeviceID": self.receiver_id, "libraryInstanceID": self.library_id,
                           "chunkID": ident, "manifestSHA256": manifest_hash, "audioSHA256": m["audioSHA256"],
                           "representation": "full"}
            # A retry repairs a file lost after commit, reusing the original receipt.
            with tempfile.TemporaryDirectory(dir=self.directory) as scratch:
                staged = Path(scratch) / path.name
                with staged.open("xb") as output:
                    output.write(audio_bytes)
                    output.flush()
                    # Flush the Mac's drive cache before the watch retires its original.
                    fcntl.fcntl(output.fileno(), fcntl.F_FULLFSYNC)
                staged.chmod(0o600)
                _validate_audio(staged, m)
                os.replace(staged, path)
                fd = os.open(self.directory, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            if old is None:
                db.execute("""INSERT INTO chunks(id,device,session,epoch,sequence,manifest,filename,receipt,recorded_at,duration)
                              VALUES(?,?,?,?,?,?,?,?,?,?)""",
                           (ident, device, session, epoch, m["sequence"],
                            manifest_bytes, path.name, json.dumps(receipt), recorded, m["frames"]["count"]/16000))
        return receipt

    def list_recordings(self, before=None, limit=50):
        limit = int(limit)
        if not 1 <= limit <= 100:
            raise ValueError("录音列表页大小无效。")
        where, args = "", []
        if before:
            try:
                stamp, ident = before.split("~", 1)
                stamp, ident = float(stamp), _uuid(ident)
                if not math.isfinite(stamp):
                    raise ValueError()
            except (ValueError, AttributeError) as exc:
                raise ValueError("录音翻页位置无效。") from exc
            where, args = "WHERE (recorded_at,id)<(?,?)", [stamp, ident]
        with self._connection() as db:
            rows = db.execute(f"""SELECT id,recorded_at,duration,transcript,state FROM chunks {where}
                               ORDER BY recorded_at DESC,id DESC LIMIT ?""", [*args, limit+1]).fetchall()
        items = [{**dict(row), "audio_url": "/api/audio/" + row["id"]} for row in rows[:limit]]
        cursor = f"{items[-1]['recorded_at']}~{items[-1]['id']}" if len(rows) > limit else None
        return {"items": items, "next_cursor": cursor}

    def audio_file(self, chunk_id):
        ident = _uuid(chunk_id)
        with self._connection() as db:
            row = db.execute("SELECT filename FROM chunks WHERE id=?", (ident,)).fetchone()
        if row is None or not (path := self.directory / row["filename"]).is_file():
            raise FileNotFoundError(ident)
        return path

    @staticmethod
    def is_ready(model_dir, executable):
        return bool(model_dir and executable and Path(executable).is_file() and os.access(executable, os.X_OK)
                    and all((Path(model_dir) / name).is_file()
                            for name in ("manifest.json", "silero_vad.onnx", "model.int8.onnx", "tokens.txt")))

    def _next(self, publishing=False):
        states = "state='ready' AND published=0" if publishing else "state IN ('queued','failed')"
        with self._connection() as db:
            row = db.execute(f"""SELECT * FROM chunks WHERE {states} AND retry_at<=?
                              ORDER BY recorded_at,id LIMIT 1""", (time.time(),)).fetchone()
            if row is not None and not publishing:
                db.execute("UPDATE chunks SET state='processing' WHERE id=?", (row["id"],))
            return row

    def _retry(self, row, *, publishing):
        attempts = row["attempts"] + 1
        delay = min(3600, 15 * 2**min(attempts-1, 8))
        with self._connection() as db:
            db.execute("UPDATE chunks SET state=?,attempts=?,retry_at=? WHERE id=?",
                       ("ready" if publishing else "failed", attempts, time.time()+delay, row["id"]))

    def _source(self, row):
        # A closed chunk is one immutable source. The original capture session stays in the manifest.
        spans = [{"id": str(uuid.uuid5(uuid.UUID(row["id"]), str(i))),
                  "text": span["text"], "recorded_at": row["recorded_at"] + span["offset"]}
                 for i, span in enumerate(json.loads(row["spans"])) if span["text"]]
        return {"library_id": self.library_id, "session_id": row["id"], "device_id": row["device"],
                "generation": 1, "version": 1, "deleted": False, "recorded_at": row["recorded_at"],
                "spans": spans, "text_sha256": hashlib.sha256(row["transcript"].encode()).hexdigest()}

    async def _publish_one(self, publish):
        row = self._next(publishing=True)
        if row is None:
            return False
        payload = self._source(row)
        try:
            receipt = await publish(payload)
            expected = f"1:1:{payload['text_sha256']}:0"
            if not isinstance(receipt, dict) or (receipt.get("source_id"), receipt.get("source_revision")) != (
                    self.library_id + "/" + row["id"], expected):
                raise ValueError("上下文服务未确认收件。")
        except Exception as exc:
            # The external callback can raise a transport or gateway-specific exception.
            # Cancellation propagates; committed speech remains independently replayable.
            LOG.warning("Context sync deferred for chunk %s (%s)", row["id"], type(exc).__name__)
            self._retry(row, publishing=True)
        else:
            with self._connection() as db:
                db.execute("UPDATE chunks SET published=1,attempts=0,retry_at=0 WHERE id=?", (row["id"],))
        return True

    async def run_worker(self, model_dir, executable, publish):
        """Run until cancelled; persisted transcripts and the publication outbox retry independently."""
        with (self.directory / "worker.lock").open("a") as lock:
            # Never reset another process's currently decoding job.
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self._connection() as db:
                db.execute("UPDATE chunks SET state='queued' WHERE state='processing'")
            async with _SpeechProcess(model_dir, executable) as speech:
                while True:
                    published = await self._publish_one(publish)
                    row = self._next() if self.is_ready(model_dir, executable) else None
                    if row is None:
                        if not published:
                            await asyncio.sleep(1.5)
                        continue
                    try:
                        spans = await speech.recognize(self.directory / row["filename"], row)
                    except (OSError, ValueError, TimeoutError, ConnectionError, asyncio.IncompleteReadError) as exc:
                        LOG.warning("Speech retry scheduled for chunk %s (%s)", row["id"], type(exc).__name__)
                        self._retry(row, publishing=False)
                        await speech.stop()
                    else:
                        with self._connection() as db:
                            db.execute("""UPDATE chunks SET state='ready', transcript=?, spans=?, attempts=0,retry_at=0
                                          WHERE id=?""",
                                       ("\n".join(s["text"] for s in spans if s["text"]), json.dumps(spans), row["id"]))


class _SpeechProcess:
    def __init__(self, models, executable):
        self.models, self.executable = models, executable
        self.process = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        await self.stop()

    async def stop(self):
        proc, self.process = self.process, None
        if proc is not None and proc.returncode is None:
            try:
                proc.terminate()
            except ProcessLookupError:
                pass
            await proc.wait()

    async def recognize(self, path, row):
        if self.process is None or self.process.returncode is not None:
            self.process = await asyncio.create_subprocess_exec(
                str(self.executable), str(self.models), stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=1024*1024)
        instance = self.process
        request = {"id": row["id"], "audio": str(path),
                   "manifest": base64.b64encode(row["manifest"]).decode("ascii")}
        async with asyncio.timeout(300):
            instance.stdin.write(json.dumps(request).encode() + b"\n")
            await instance.stdin.drain()
            result = json.loads(await instance.stdout.readline())
        if (not isinstance(result, dict) or _uuid(result.get("id")) != row["id"]
                or not isinstance(result.get("spans"), list)):
            raise ValueError("转写进程未返回有效结果。")
        for span in result["spans"]:
            if (not isinstance(span, dict) or type(span.get("offset")) not in (int, float) or
                    not 0 <= span["offset"] < row["duration"] or not isinstance(span.get("text"), str)):
                raise ValueError("转写时间或正文无效。")
        return result["spans"]
