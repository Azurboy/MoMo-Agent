"""Serve the mobile client beside an installed MoMo Agent for Mac."""
from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
from contextlib import suppress
import json
import os
from pathlib import Path
import signal
import uuid
from urllib.parse import urlsplit

from aiohttp import ClientError, ClientSession, ClientTimeout, web
from access import MobileAccess
from recordings import RecordingArchive, RecordingConflict

ROOT = Path(__file__).resolve().parents[2]
PUBLIC = Path(__file__).with_name("public")
ASSETS = ROOT / "Apps/iPhoneApp/Resources/Assets.xcassets"
VENDOR = ROOT / "Apps/iPhoneApp/Features/Assistant/Rendering/Web/vendor"
BRAND = {
    "icon.png": ASSETS / "AppIcon.appiconset/AppIcon.png",
    "wordmark.svg": ASSETS / "PhoneWordmark.imageset/PhoneWordmark.svg",
    "momo.svg": ASSETS / "MoMoWordmark.imageset/MoMoWordmark.svg",
    "avatar.js": VENDOR / "momoagent-avatar.js",
    "marked.js": VENDOR / "marked.js",
    "purify.js": VENDOR / "purify.js",
}
SESSION = "momo_web_device"


def problem(message, status):
    return web.json_response({"error": message}, status=status)


def canonical_origin(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("请输入手表和手机可以访问的 HTTPS 地址（只含域名和可选端口）。")
    return "https://" + parsed.netloc.lower()


@web.middleware
async def headers(request, handler):
    try:
        response = await handler(request)
    except web.HTTPException as error:
        response = problem(error.reason, error.status)
    except (ValueError, TypeError, KeyError, binascii.Error):
        response = problem("请求格式有误", 400)
    response.headers.update({
        "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
        "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'self'",
    })
    return response


async def json_body(request, limit=32_768):
    if request.content_type != "application/json":
        raise web.HTTPUnsupportedMediaType()
    if request.content_length is not None and request.content_length > limit:
        raise web.HTTPRequestEntityTooLarge(max_size=limit, actual_size=request.content_length)
    raw = await request.read()
    if len(raw) > limit:
        raise web.HTTPRequestEntityTooLarge(max_size=limit, actual_size=len(raw))
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("Expected object")
    return value


class MacAgent:
    def __init__(self, data, session):
        self.data, self.session = data, session

    async def request(self, path, *, context=False, body=None, params=None, device=None):
        # The Mac owns the credential and may rotate it while this service is running.
        try:
            connection = json.loads((self.data / "connection.json").read_bytes())
            secret = (self.data / "api-key").read_text().strip()
            origin = connection["data_url" if context else "base_url"]
            parsed = urlsplit(origin)
            if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1") or parsed.username or parsed.password:
                raise ValueError("Expected the local MoMo service")
            auth = {"Authorization": "Bearer " + secret, "X-MoMo-Session-Key": "momo:" + connection["assistant_id"]}
            if device:
                auth["X-MoMo-Device"] = device
            async with self.session.request("GET" if body is None else "POST", origin.rstrip("/") + path,
                                            params=params, json=body, headers=auth, allow_redirects=False) as upstream:
                if upstream.status >= 500 or upstream.status in (401, 403) or 300 <= upstream.status < 400:
                    raise web.HTTPServiceUnavailable(reason="Mac 服务暂时不可用")
                answer = await upstream.json()
                return upstream.status, answer
        except (OSError, ClientError, TimeoutError, KeyError, ValueError) as error:
            raise web.HTTPServiceUnavailable(reason="请在 Mac 打开 MoMo Agent") from error

    async def publish(self, payload):
        code, answer = await self.request("/v1/sources", context=True, body=payload)
        if code != 200:
            raise RuntimeError("Mac 未接收转录资料")
        return answer


class MobileWeb:
    def __init__(self, access, archive, agent, port, owner_port, public_url, models, binary):
        self.access, self.archive, self.agent = access, archive, agent
        self.models, self.binary = models, binary
        self.port, self.owner_port, self.public_url = port, owner_port, public_url

    def origin(self, request, owner=False):
        host = request.headers.get("Host", "").lower()
        port = self.owner_port if owner else self.port
        if not owner and self.public_url and host == urlsplit(self.public_url).netloc:
            return self.public_url
        if host in (f"localhost:{port}", f"127.0.0.1:{port}", f"[::1]:{port}"):
            return "http://" + host
        raise web.HTTPForbidden(reason="此地址未被 Mac 配置为访问入口")

    def guard(self, owner=False):
        @web.middleware
        async def check(request, handler):
            expected = self.origin(request, owner)
            if request.method not in ("GET", "HEAD"):
                origin = request.headers.get("Origin")
                if (origin and origin != expected) or (owner and origin != expected):
                    raise web.HTTPForbidden(reason="访问来源不匹配")
            return await handler(request)
        return check

    def browser(self, request):
        grant = self.access.grant("browser", request.cookies.get(SESSION))
        if grant is None:
            raise web.HTTPUnauthorized(reason="请先与 Mac 配对")
        return grant

    def watch(self, request):
        scheme, _, token = request.headers.get("Authorization", "").partition(" ")
        grant = self.access.grant("watch", token) if scheme == "Bearer" else None
        if grant is None:
            raise web.HTTPUnauthorized(reason="请重新连接 Mac")
        return grant

    async def pair(self, request):
        body = await json_body(request)
        role = body.get("role")
        token = self.access.pair(role, body.get("code"), body.get("device_id"))
        if not token:
            return problem("配对码已失效，请在 Mac 上重新生成", 403)
        if role == "watch":
            return web.json_response({"token": token, **self.access.identity})
        response = web.json_response({"authorized": True})
        response.set_cookie(SESSION, token, httponly=True, secure=self.origin(request).startswith("https:"),
                            samesite="Strict", path="/", max_age=365 * 86_400)
        return response

    async def logout(self, request):
        self.access.forget(self.browser(request)["id"])
        response = web.json_response({"authorized": False})
        response.del_cookie(SESSION, path="/")
        return response

    async def status(self, request):
        self.browser(request)
        try:
            async with asyncio.timeout(3):
                code, _ = await self.agent.request("/v1/capabilities")
            online = code == 200
        except (web.HTTPServiceUnavailable, TimeoutError):
            online = False
        return web.json_response({"authorized": True, "mac": {"online": online},
                                  "watch": self.access.watch_status(), "asr": self.archive.is_ready(self.models, self.binary)})

    async def read_mac(self, request):
        self.browser(request)
        paths = {"/api/chat": ("/momo/v1/conversation/snapshot", False, set()),
                 "/api/chat/history": ("/momo/v1/conversation/messages", False, {"before", "limit"}),
                 "/api/memories": ("/v1/memories", True, {"after", "limit", "revision"}),
                 "/api/sources": ("/v1/sources", True, {"after", "limit", "summarize"}),
                 "/api/source": ("/v1/source", True, {"source_id", "revision", "offset", "limit"})}
        path, context, allowed = paths[request.path]
        if not set(request.query) <= allowed or len(request.query_string) > 4096:
            raise ValueError("Invalid query")
        code, answer = await self.agent.request(path, context=context, params=request.query)
        return web.json_response(answer, status=code)

    async def chat(self, request):
        grant = self.browser(request)
        body = await json_body(request, 100_000)
        operation = str(uuid.UUID(body["operation_id"]))
        message = body.get("content")
        if not isinstance(message, str) or not message.strip() or len(message.encode()) > 16_384:
            raise ValueError("Invalid message")
        code, answer = await self.agent.request("/momo/v1/conversation/messages", device=grant["id"],
            body={"operation_id": operation, "content": message, "intent": "new"})
        return web.json_response(answer, status=code)

    async def upload(self, request):
        grant = self.watch(request)
        if request.content_type != "application/octet-stream":
            raise web.HTTPUnsupportedMediaType()
        encoded = request.headers.get("X-MoMo-Manifest", "")
        if not encoded or len(encoded) > 22_000:
            raise ValueError("Invalid manifest")
        try:
            receipt = await asyncio.to_thread(self.archive.receive, grant["device"], request.match_info["id"],
                                              base64.b64decode(encoded, validate=True), await request.read())
        except RecordingConflict:
            return problem("同一录音片段的内容不一致，已保留原音", 409)
        self.access.watch_seen(grant["id"])
        return web.json_response(receipt)

    async def heartbeat(self, request):
        grant = self.watch(request)
        body = await json_body(request)
        if type(body.get("recording")) is not bool or type(body.get("pending")) is not int or not 0 <= body["pending"] <= 2**31:
            raise ValueError("Invalid watch status")
        self.access.watch_seen(grant["id"], body["recording"], body["pending"])
        return web.json_response({"ok": True})

    async def recordings(self, request):
        self.browser(request)
        listing = self.archive.list_recordings(before=request.query.get("before"), limit=50)
        return web.json_response(listing)

    async def audio(self, request):
        self.browser(request)
        try:
            path = self.archive.audio_file(str(uuid.UUID(request.match_info["id"])))
        except (FileNotFoundError, ValueError):
            raise web.HTTPNotFound()
        return web.FileResponse(path, headers={"Content-Type": "audio/wav" if path.suffix == ".wav" else "audio/mp4"})

    async def static(self, request):
        name = request.match_info.get("file", "")
        if request.path.startswith("/assets/"):
            path = BRAND.get(name)
        else:
            name = {"": "index.html", "install": "install.html", "install/": "install.html"}.get(name, name)
            path = (PUBLIC / name).resolve()
            if not path.is_relative_to(PUBLIC.resolve()) or any(part.startswith(".") for part in Path(name).parts):
                raise web.HTTPNotFound()
        if not path or not path.is_file():
            raise web.HTTPNotFound()
        return web.FileResponse(path)

    async def manage(self, request):
        return web.FileResponse(Path(__file__).with_name("manage.html"))

    async def management_asset(self, request):
        if request.path == "/manage.js":
            return web.FileResponse(Path(__file__).with_name("manage.js"))
        return web.FileResponse(Path(__file__).with_name("manage.css"))

    async def owner_info(self, request):
        devices = [dict(r) for r in self.access.db.execute("SELECT id,role,created,last_seen FROM grants ORDER BY created DESC")]
        return web.json_response({"local": f"http://127.0.0.1:{self.port}/", "public": self.public_url, "devices": devices})

    async def owner_action(self, request):
        body = await json_body(request)
        if request.path == "/revoke":
            return web.json_response({"revoked": bool(self.access.forget(str(uuid.UUID(body["id"]))))})
        return web.json_response({"code": self.access.issue(body["role"]), "expires_in": 600})

    def application(self, owner=False):
        app = web.Application(middlewares=[headers, self.guard(owner)], client_max_size=8_000_000)
        if owner:
            app.add_routes([web.get("/", self.manage), web.get("/manage.js", self.management_asset),
                            web.get("/css", self.management_asset),
                            web.get("/info", self.owner_info), web.post("/invite", self.owner_action), web.post("/revoke", self.owner_action)])
            return app
        app.add_routes([web.post("/api/pair", self.pair), web.post("/api/logout", self.logout),
                        web.get("/api/status", self.status), web.post("/api/chat", self.chat),
                        web.put("/api/watch/chunks/{id}", self.upload), web.post("/api/watch/status", self.heartbeat),
                        web.get("/api/recordings", self.recordings), web.get("/api/audio/{id}", self.audio)])
        for name in ("chat", "chat/history", "memories", "sources", "source"):
            app.router.add_get("/api/" + name, self.read_mac)
        app.router.add_get("/assets/{file}", self.static)
        app.router.add_get("/{file:.*}", self.static)
        return app


async def serve(args):
    os.umask(0o077)
    access = MobileAccess(args.data / "access")
    archive = RecordingArchive(args.data / "recordings", access.identity["receiver_id"], access.identity["library_id"])
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopped.set)
    runners = []
    try:
        async with ClientSession(timeout=ClientTimeout(total=50, sock_connect=3), trust_env=False) as session:
            agent = MacAgent(args.agent_data, session)
            service = MobileWeb(access, archive, agent, args.port, args.owner_port, args.public_url, args.models, args.speech_binary)
            worker = None
            try:
                for owner, port in [(True, args.owner_port), (False, args.port)]:
                    runner = web.AppRunner(service.application(owner), access_log=None, max_field_size=24_000)
                    await runner.setup()
                    runners.append(runner)
                    await web.TCPSite(runner, "127.0.0.1", port).start()
                worker = asyncio.create_task(archive.run_worker(args.models, args.speech_binary, agent.publish))
                print(f"在这台 Mac 上配对设备：http://127.0.0.1:{args.owner_port}/", flush=True)
                await stopped.wait()
            finally:
                for runner in reversed(runners):
                    await runner.cleanup()
                if worker is not None:
                    worker.cancel()
                    with suppress(asyncio.CancelledError):
                        await worker
    finally:
        archive.close()
        access.db.close()


if __name__ == "__main__":
    home = Path.home() / "Library/Application Support/MoMoAgent"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent-data", type=Path, default=home / "Agent")
    parser.add_argument("--data", type=Path, default=home / "MobileWeb")
    parser.add_argument("--port", type=int, default=8789)
    parser.add_argument("--owner-port", type=int, default=18790)
    parser.add_argument("--public-url", type=canonical_origin, default=os.environ.get("MOMO_WEB_ORIGIN"))
    parser.add_argument("--models", type=Path, default=Path(os.getenv("MOMO_SPEECH_MODELS", ROOT / "Models/Speech")))
    parser.add_argument("--speech-binary", type=Path, default=Path(os.getenv("MOMO_WEB_SPEECH_BINARY", Path(__file__).with_name("Speech") / ".build/release/momo-web-speech")))
    asyncio.run(serve(parser.parse_args()))
