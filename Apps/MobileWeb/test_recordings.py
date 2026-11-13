import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
import uuid
import wave

from recordings import RecordingArchive, RecordingConflict, _SpeechProcess


def uid():
    return str(uuid.uuid4())


def silence(frames=16_000):
    data = io.BytesIO()
    with wave.open(data, "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "none"))
        output.writeframes(bytes(frames * 2))
    return data.getvalue()


class ArchiveFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "archive"
        self.receiver, self.library, self.device, self.session, self.epoch = (uid() for _ in range(5))
        self.archive = RecordingArchive(self.directory, self.receiver, self.library)
        self.raw = silence()

    def manifest(self, *, data=None, sequence=1, frames=16000, codec="pcmInt16", start=960000):
        data = self.raw if data is None else data
        frame_range = {"start": start, "count": frames}
        return {"manifestVersion": 1, "sessionID": self.session, "epochID": self.epoch,
                "chunkID": uid(), "sourceDeviceID": self.device, "sourceBuild": "123",
                "sequence": sequence, "frames": frame_range, "timebaseHz": 16000,
                "wallClockAnchor": "2026-11-13T00:00:00.123Z", "timezoneOffset": 28800,
                "codec": codec, "sampleRate": 16000, "channels": 1, "decodedFrameCount": frames,
                "primingFrames": 0, "paddingFrames": 0, "byteCount": len(data),
                "audioSHA256": hashlib.sha256(data).hexdigest(), "sealedAt": "2026-11-13T00:02:00Z",
                "representation": "full", "sourceRanges": [frame_range], "sourceKind": "watch"}

    def receive(self, manifest, data=None):
        return self.archive.receive(self.device, manifest["chunkID"], json.dumps(manifest).encode(),
                                    self.raw if data is None else data)


class ReceiptTests(ArchiveFixture, unittest.TestCase):
    def test_receipt_survives_restart_and_concurrent_retries(self):
        manifest = self.manifest()
        with ThreadPoolExecutor(max_workers=4) as pool:
            replies = list(pool.map(self.receive, [manifest] * 4))
        self.assertEqual(replies, [replies[0]] * 4)
        self.assertEqual(replies[0]["manifestSHA256"], hashlib.sha256(json.dumps(manifest).encode()).hexdigest())
        self.assertEqual(replies[0]["receiverDeviceID"], self.receiver)
        self.assertEqual(replies[0]["libraryInstanceID"], self.library)
        self.archive = RecordingArchive(self.directory, self.receiver, self.library)
        self.assertEqual(self.receive(manifest), replies[0])
        audio = self.archive.audio_file(manifest["chunkID"])
        self.assertEqual(audio.read_bytes(), self.raw)
        audio.unlink()
        self.assertEqual(self.receive(manifest), replies[0])
        self.assertEqual(audio.read_bytes(), self.raw)
        self.assertEqual(self.archive.list_recordings()["items"], [{
            "id": manifest["chunkID"], "duration": 1.0, "recorded_at": 1794528060.123,
            "state": "queued", "transcript": "", "audio_url": "/api/audio/" + manifest["chunkID"]}])

    def test_conflicting_manifest_or_sequence_preserves_original(self):
        manifest = self.manifest()
        original = self.receive(manifest)
        with self.assertRaises(RecordingConflict):
            self.receive({**manifest, "sourceBuild": "124"})
        with self.assertRaises(RecordingConflict):
            self.receive({**manifest, "chunkID": uid()})
        with self.assertRaises(RecordingConflict):
            self.receive(self.manifest(sequence=2, start=manifest["frames"]["start"] + 2000))
        with self.assertRaises(RecordingConflict):
            self.receive({**self.manifest(sequence=2, start=0), "sessionID": uid()})
        with self.assertRaises(RecordingConflict):
            RecordingArchive(self.directory, self.receiver, uid())
        self.assertEqual(self.receive(manifest), original)

    def test_rejected_media_does_not_enter_the_archive(self):
        manifest = self.manifest()
        for changes in ({"sourceKind": "phone"}, {"representation": "preview"}, {"sourceDeviceID": uid()},
                        {"epochID": "broken"}, {"wallClockAnchor": "2026-11-13"}, {"sourceRanges": []},
                        {"audioSHA256": "0" * 64}, {"byteCount": len(self.raw) + 1}, {"codec": "aac"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.receive({**manifest, **changes})
        with self.assertRaises(ValueError):
            self.receive(self.manifest(frames=8000))
        truncated = self.raw[:len(self.raw) // 2]
        with self.assertRaises(ValueError):
            self.receive(self.manifest(data=truncated), truncated)
        self.assertEqual(self.archive.list_recordings()["items"], [])
        with self.assertRaises(FileNotFoundError):
            self.archive.audio_file(manifest["chunkID"])

    def test_filesystem_write_failure_retries_with_intact_contents(self):
        manifest = self.manifest()
        with patch("recordings.os.fsync", side_effect=OSError("disk unavailable")), self.assertRaises(OSError):
            self.receive(manifest)
        self.assertEqual(self.archive.list_recordings()["items"], [])
        self.assertEqual(self.receive(manifest)["audioSHA256"], manifest["audioSHA256"])

    def test_pagination_includes_ties_and_out_of_order_arrivals(self):
        chunks = [self.manifest(sequence=i, start=0 if i < 2 else 16_000) for i in range(3)]
        chunks[1]["epochID"] = uid()
        for index in (2, 0, 1):
            self.receive(chunks[index])
        expected = [chunks[2]["chunkID"], *sorted((m["chunkID"] for m in chunks[:2]), reverse=True)]
        found, cursor = [], None
        for _ in chunks:
            page = self.archive.list_recordings(before=cursor, limit=1)
            found.append(page["items"][0]["id"])
            cursor = page["next_cursor"]
        self.assertIsNone(cursor)
        self.assertEqual(found, expected)
        with self.assertRaises(ValueError):
            self.archive.list_recordings(before="yesterday")


class WorkerTests(ArchiveFixture, unittest.IsolatedAsyncioTestCase):
    async def run_until(self, archive, models, binary, publish, event):
        worker = asyncio.create_task(archive.run_worker(models, binary, publish))
        try:
            await asyncio.wait_for(event.wait(), 90)
        finally:
            worker.cancel()
            await asyncio.gather(worker, return_exceptions=True)
        if not worker.cancelled():
            worker.result()

    async def test_recover_processing_then_republish_without_transcribing_again(self):
        manifest = self.manifest()
        self.receive(manifest)
        with closing(sqlite3.connect(self.archive.database)) as db, db:
            db.execute("UPDATE chunks SET state='processing'")
        attempted = asyncio.Event()
        payloads = []
        async def unavailable(payload):
            payloads.append(payload)
            attempted.set()
            raise ConnectionError("context offline")
        first_result = [{"offset": 0.1, "text": "测试", "nativeResult": "{}"},
                        {"offset": 0.5, "text": "", "nativeResult": "{}"}]
        with patch.object(self.archive, "is_ready", return_value=True), patch.object(
                _SpeechProcess, "recognize", new=AsyncMock(return_value=first_result)) as recognize:
            await self.run_until(self.archive, None, None, unavailable, attempted)
            recognize.assert_awaited_once()
        self.assertEqual(self.archive.list_recordings()["items"][0]["transcript"], "测试")
        with closing(sqlite3.connect(self.archive.database)) as db, db:
            status, published, spans = db.execute("SELECT state,published,spans FROM chunks").fetchone()
            self.assertEqual((status, published, json.loads(spans)), ("ready", 0, first_result))
            db.execute("UPDATE chunks SET retry_at=0")
        restarted = RecordingArchive(self.directory, self.receiver, self.library)
        delivered = asyncio.Event()
        async def online(payload):
            payloads.append(payload)
            delivered.set()
            return {"source_id": self.library + "/" + manifest["chunkID"],
                    "source_revision": "1:1:" + payload["text_sha256"] + ":0", "revision": 1}
        # No model installed during recovery. Already-completed speech still reaches the Agent.
        await self.run_until(restarted, None, None, online, delivered)
        self.assertEqual(payloads[0], payloads[1])
        self.assertEqual(len(payloads[1]["spans"]), 1)
        self.assertAlmostEqual(payloads[1]["spans"][0]["recorded_at"], 1794528060.223, places=6)
        with closing(sqlite3.connect(self.archive.database)) as db, db:
            self.assertEqual(db.execute("SELECT published FROM chunks").fetchone(), (1,))

    @unittest.skipUnless(RecordingArchive.is_ready(os.getenv("MOMO_SPEECH_MODELS"), os.getenv("MOMO_WEB_SPEECH_BINARY")),
                         "Set MOMO_SPEECH_MODELS and MOMO_WEB_SPEECH_BINARY for native speech integration")
    async def test_real_aac_and_silence_through_context_store(self):
        repo = Path(__file__).resolve().parents[2]
        sys.path.insert(0, str(repo / "Apps/MacApp/Context"))
        self.addCleanup(sys.path.pop, 0)
        from context_store import ContextStore
        context = ContextStore(Path(self.temp.name) / "context")
        self.addCleanup(context.db.close)
        # The fixture is the short English speech sample already shipped with the repository.
        clip = repo / "Vendor/HermesAgent/tools/neutts_samples/jo.wav"
        wav, aac = (Path(self.temp.name) / name for name in ("sample.wav", "sample.m4a"))
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", clip, wav], check=True)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "24000", wav, aac], check=True)
        data = aac.read_bytes()
        with wave.open(str(wav)) as reader:
            speech = self.manifest(data=data, codec="aac", frames=reader.getnframes(), start=960000)
        quiet = self.manifest(sequence=2, start=1920000)
        self.receive(quiet)
        self.receive(speech, data)
        event, payloads = asyncio.Event(), []
        async def publish(payload):
            reply = context.sync_source(payload)
            payloads.append(payload)
            if len(payloads) == 2:
                event.set()
            return reply
        await self.run_until(self.archive, os.environ["MOMO_SPEECH_MODELS"], os.environ["MOMO_WEB_SPEECH_BINARY"],
                             publish, event)
        quiet_row, speech_row = self.archive.list_recordings()["items"]
        self.assertEqual((quiet_row["state"], quiet_row["transcript"]), ("ready", ""))
        self.assertIn("voice", speech_row["transcript"].lower())
        self.assertEqual([p["session_id"] for p in payloads], [speech["chunkID"], quiet["chunkID"]])
        self.assertEqual(payloads[1]["spans"], [])
        self.assertEqual(self.archive.audio_file(speech["chunkID"]).read_bytes(), data)


if __name__ == "__main__":
    unittest.main()
