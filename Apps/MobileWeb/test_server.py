import base64
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import uuid
import wave

from aiohttp import DummyCookieJar
from aiohttp.test_utils import TestClient, TestServer

from access import MobileAccess
from recordings import RecordingArchive
from server import MobileWeb


class StubMac:
    async def request(self, path, **kwargs):
        return 200, {"route": path, "body": kwargs.get("body")}


class StubArchive:
    def is_ready(self, *args):
        return True

    def receive(self, device, ident, manifest, audio):
        return {"chunkID": ident, "device": device, "bytes": len(audio)}


class MobileWebTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.access = MobileAccess(Path(self.temp.name))
        self.service = MobileWeb(self.access, StubArchive(), StubMac(), 8789, 8790, "https://momo.example", None, None)
        self.client = TestClient(TestServer(self.service.application()), cookie_jar=DummyCookieJar(), headers={"Host": "127.0.0.1:8789"})
        self.owner = TestClient(TestServer(self.service.application(True)), headers={"Host": "127.0.0.1:8790"})
        await self.client.start_server()
        await self.owner.start_server()

    async def asyncTearDown(self):
        await self.owner.close()
        await self.client.close()
        self.access.db.close()
        self.temp.cleanup()

    async def pair_browser(self):
        response = await self.client.post("/api/pair", json={"role": "browser", "code": self.access.issue("browser")})
        self.assertEqual(response.status, 200)
        return {"Cookie": "momo_web_device=" + response.cookies["momo_web_device"].value}

    async def test_browser_watch_roles_revoke_and_home_screen(self):
        self.assertEqual((await self.client.get("/api/chat")).status, 401)
        self.assertEqual((await self.client.get("/invite")).status, 404)
        self.assertEqual((await self.client.get("/manage.js")).status, 404)
        self.assertEqual((await self.client.get("/install")).status, 200)
        self.assertEqual((await self.client.get("/manifest.webmanifest")).status, 200)
        self.assertEqual((await self.owner.post("/invite", json={"role":"browser"})).status, 403)
        cookie = await self.pair_browser()
        self.assertEqual((await self.client.get("/api/chat", headers=cookie)).status, 200)
        self.assertEqual((await self.client.post("/api/chat", headers={**cookie, "Origin":"https://other.example"},
                                                json={"operation_id":str(uuid.uuid4()), "content":"test"})).status, 403)
        self.assertEqual((await self.client.post("/api/watch/status", headers=cookie, json={})).status, 401)
        watch = str(uuid.uuid4())
        code = self.access.issue("watch")
        args = {"role": "watch", "code": code, "device_id": watch}
        paired = await self.client.post("/api/pair", json=args)
        body = await paired.json()
        self.assertEqual(body["library_id"], self.access.identity["library_id"])
        self.assertEqual((await self.client.post("/api/pair", json=args)).status, 403)
        auth = {"Authorization":"Bearer " + body["token"]}
        self.assertEqual((await self.client.get("/api/memories", headers=auth)).status, 401)
        self.assertEqual((await self.client.post("/api/watch/status", headers=auth, json={"recording":True,"pending":3})).status, 200)
        chunk = str(uuid.uuid4())
        sent = await self.client.put("/api/watch/chunks/" + chunk, headers={**auth,"X-MoMo-Manifest":base64.b64encode(b"{}").decode()}, data=b"abcd")
        self.assertEqual((await sent.json())["chunkID"], chunk)
        self.assertEqual((await (await self.client.get("/api/status",headers=cookie)).json())["watch"]["pending"], 3)
        self.assertEqual((await self.client.post("/api/logout",headers=cookie)).status, 200)
        self.assertEqual((await self.client.get("/api/chat",headers=cookie)).status, 401)

    async def test_configured_origin_cookie_and_host(self):
        self.assertEqual((await self.client.get("/", headers={"Host":"unrelated.invalid"})).status,403)
        response = await self.client.post("/api/pair", headers={"Host":"momo.example","Origin":"https://momo.example"},
                                          json={"role":"browser","code":self.access.issue("browser")})
        cookie = response.cookies["momo_web_device"]
        self.assertTrue(cookie["secure"])
        self.assertTrue(cookie["httponly"])
        self.assertEqual(cookie["samesite"], "Strict")

    async def test_watch_original_can_be_played_while_waiting_for_transcription(self):
        self.service.archive = RecordingArchive(Path(self.temp.name) / "recordings",
            self.access.identity["receiver_id"], self.access.identity["library_id"])
        device, chunk = str(uuid.uuid4()), str(uuid.uuid4())
        paired = await self.client.post("/api/pair", json={
            "role": "watch", "code": self.access.issue("watch"), "device_id": device})
        watch = {"Authorization": "Bearer " + (await paired.json())["token"]}
        sample = io.BytesIO()
        frames = 16_000
        with wave.open(sample, "wb") as wav:
            wav.setparams((1, 2, 16_000, 0, "NONE", "none"))
            wav.writeframes(bytes(frames * 2))
        raw = sample.getvalue()
        frame_range = {"start": 0, "count": frames}
        manifest = {
            "manifestVersion": 1, "sessionID": str(uuid.uuid4()), "epochID": str(uuid.uuid4()),
            "chunkID": chunk, "sourceDeviceID": device, "sourceBuild": "test", "sequence": 0,
            "frames": frame_range, "timebaseHz": 16_000, "wallClockAnchor": "2026-11-01T01:00:00Z",
            "timezoneOffset": 0, "codec": "pcmInt16", "sampleRate": 16_000, "channels": 1,
            "decodedFrameCount": frames, "primingFrames": 0, "paddingFrames": 0, "byteCount": len(raw),
            "audioSHA256": hashlib.sha256(raw).hexdigest(), "sealedAt": "2026-11-01T01:00:01Z",
            "representation": "full", "sourceRanges": [frame_range], "sourceKind": "watch"}
        upload = {**watch, "X-MoMo-Manifest": base64.b64encode(json.dumps(manifest).encode()).decode()}
        route = "/api/watch/chunks/" + chunk
        first = await self.client.put(route, headers=upload, data=raw)
        self.assertEqual(first.status, 200)
        receipt = await first.json()
        again = await self.client.put(route, headers=upload, data=raw)
        self.assertEqual(await again.json(), receipt)
        self.assertEqual(receipt["audioSHA256"], manifest["audioSHA256"])
        browser = await self.pair_browser()
        listing = await self.client.get("/api/recordings", headers=browser)
        item, = (await listing.json())["items"]
        self.assertEqual((item["state"], item["duration"]), ("queued", 1.0))
        self.assertEqual((await self.client.get(item["audio_url"])).status, 401)
        seek = await self.client.get(item["audio_url"], headers={**browser, "Range": "bytes=17-99"})
        self.assertEqual((seek.status, seek.headers.get("Content-Range")), (206, "bytes 17-99/" + str(len(raw))))
        self.assertEqual(await seek.read(), raw[17:100])


if __name__ == "__main__":
    unittest.main()
