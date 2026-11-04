"""MoMo Agent <-> DeepSeek SuperAgent gateway, proactive life-context bridge, and dsh supervisor."""
from __future__ import annotations

import asyncio
import base64
from contextlib import suppress
from datetime import datetime
import hashlib
import hmac
import json
import logging
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import time
from urllib.parse import quote, unquote
import urllib.error
import urllib.request
import uuid

from aiohttp import web

REPOSITORY = Path(__file__).resolve().parents[3]
if str(REPOSITORY / "Apps/MacApp/Runtime") not in sys.path:
    sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Runtime"))
if str(REPOSITORY / "Apps/MacApp/Context") not in sys.path:
    sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Context"))
if str(REPOSITORY / "Vendor/HermesAgent") not in sys.path:
    sys.path.insert(0, str(REPOSITORY / "Vendor/HermesAgent"))

from context_store import logical_local_date, read_day_start_hour
from conversation_store import ProductStore, collect_deliverable_attachments
from superagent_computer import SuperAgentComputer
from push_notifications import PushOutbox, load_provider
from runtime_engine import PROACTIVE_MODES, read_engine_config, write_engine_config
from superagent_runtime import (
    classify_transcript_span,
    dsh_api_request,
    format_transcript_span_line,
    is_filler_only_utterance,
    node_environment,
    prepare_dsh_instance,
    prepare_superagent,
    prepared_dsh_binary,
    resolve_superagent_llm,
    seed_superagent_orchestrator,
    superagent_fingerprint,
)

log = logging.getLogger("momo.superagent_gateway")

CAPABILITIES = dict(
    shared_conversation=True,
    server_owned_completion=True,
    durable_steering=True,
    independent_chat_while_waiting=True,
    system_push=False,
    message_streaming=True,
    conversation_events=True,
    proactive_agent=True,
)


def _conflict(code: str) -> None:
    raise web.HTTPConflict(
        text=json.dumps({"error": {"code": code, "message": code}}),
        content_type="application/json",
    )


def _allocate_loopback_port(avoid: set[int]) -> int:
    for _ in range(32):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            port = int(sock.getsockname()[1])
            if port not in avoid:
                return port
    raise RuntimeError("Could not allocate a free loopback port for dsh-superagent")


class BridgeStore:
    """Durable SQLite ledger for SuperAgent triggers, run projections, proactive watermarks, and /v1/runs."""

    RETENTION_SECONDS = 86400

    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(path, timeout=10, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(
            """
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS triggers(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT UNIQUE NOT NULL,
                kind TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                source_id TEXT,
                title TEXT,
                actor_id TEXT NOT NULL,
                actor_name TEXT,
                addressed INTEGER NOT NULL,
                human INTEGER NOT NULL,
                observed INTEGER NOT NULL,
                text TEXT NOT NULL,
                at_iso TEXT NOT NULL,
                run_id TEXT,
                polled_at REAL
            );
            CREATE TABLE IF NOT EXISTS chat_runs(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id TEXT UNIQUE NOT NULL,
                operation_id TEXT,
                session_id TEXT NOT NULL,
                work_id TEXT NOT NULL,
                title TEXT NOT NULL,
                status TEXT NOT NULL,
                trigger_id TEXT,
                ticket_id TEXT,
                intent TEXT NOT NULL DEFAULT 'new',
                delivery_state TEXT,
                execution_generation INTEGER NOT NULL DEFAULT 1,
                wait_reason TEXT,
                cancellable INTEGER NOT NULL DEFAULT 1,
                cancel_requested INTEGER NOT NULL DEFAULT 0,
                error TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS outbound_receipts(
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                ticket_id TEXT,
                message_id TEXT,
                created_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS source_watermarks(
                source_id TEXT PRIMARY KEY,
                revision TEXT NOT NULL,
                max_seq INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                last_recorded_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS api_runs(
                run_id TEXT PRIMARY KEY,
                idempotency_key TEXT UNIQUE,
                session_id TEXT NOT NULL,
                input_text TEXT NOT NULL,
                status TEXT NOT NULL,
                output_text TEXT,
                error_text TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        )
        with suppress(sqlite3.OperationalError):
            self.db.execute("ALTER TABLE triggers ADD COLUMN title TEXT")
        with suppress(sqlite3.OperationalError):
            self.db.execute("ALTER TABLE source_watermarks ADD COLUMN last_recorded_at REAL NOT NULL DEFAULT 0")
        path.chmod(0o600)

    def close(self) -> None:
        self.db.close()

    def enqueue_trigger(
        self,
        *,
        trigger_id: str,
        kind: str,
        thread_id: str,
        message_id: str,
        actor_id: str = "owner",
        actor_name: str = "User",
        addressed: bool,
        human: bool = True,
        observed: bool,
        text: str,
        source_id: str | None = None,
        title: str | None = None,
        run_id: str | None = None,
        at_iso: str | None = None,
    ) -> dict:
        timestamp = at_iso or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self.db:
            self.db.execute(
                """INSERT OR IGNORE INTO triggers(
                       id, kind, thread_id, message_id, source_id, title, actor_id, actor_name,
                       addressed, human, observed, text, at_iso, run_id
                   ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    trigger_id,
                    kind,
                    thread_id,
                    message_id,
                    source_id,
                    title,
                    actor_id,
                    actor_name,
                    int(addressed),
                    int(human),
                    int(observed),
                    text,
                    timestamp,
                    run_id,
                ),
            )
        row = self.db.execute("SELECT * FROM triggers WHERE id=?", (trigger_id,)).fetchone()
        return dict(row)

    def list_triggers(self, after: int, limit: int = 50) -> tuple[list[dict], str, list[str]]:
        rows = self.db.execute(
            "SELECT * FROM triggers WHERE seq > ? ORDER BY seq ASC LIMIT ?",
            (after, limit),
        ).fetchall()
        if not rows:
            top = self.db.execute("SELECT coalesce(max(seq), 0) FROM triggers").fetchone()[0]
            return [], str(max(after, int(top))), []
        now = time.time()
        polled_runs: list[str] = []
        items: list[dict] = []
        with self.db:
            for row in rows:
                if row["polled_at"] is None:
                    self.db.execute("UPDATE triggers SET polled_at=? WHERE seq=?", (now, row["seq"]))
                    if row["run_id"]:
                        polled_runs.append(row["run_id"])
                raw_id = str(row["id"])
                event_id = raw_id[len("momo:") :] if raw_id.startswith("momo:") else raw_id
                event: dict = {
                    "cursor": str(row["seq"]),
                    "id": event_id,
                    "stream": row["kind"],
                    "thread_id": row["thread_id"],
                    "actor_id": row["actor_id"],
                    "human": bool(row["human"]),
                    "at": row["at_iso"],
                    "text": row["text"],
                    "reply_allowed": True,
                }
                if row["actor_name"]:
                    event["actor_name"] = row["actor_name"]
                if row["addressed"]:
                    event["addressed"] = "direct"
                if row["source_id"]:
                    event["source_id"] = row["source_id"]
                if row["title"]:
                    event["title"] = row["title"]
                items.append(event)
        return items, str(int(rows[-1]["seq"])), polled_runs

    def coalesce_unpolled_transcripts(self, *, max_chars: int = 2400) -> int:
        """Merge backlogged micro-chunk transcript triggers for the same (source_id, thread_id) while preserving monotonic seq."""
        rows = self.db.execute(
            """SELECT seq, thread_id, source_id, actor_id, title, text
               FROM triggers
               WHERE polled_at IS NULL AND kind='transcripts' AND source_id IS NOT NULL
               ORDER BY seq ASC"""
        ).fetchall()
        if len(rows) <= 1:
            return 0
        by_group: dict[tuple[str, str, str], list[sqlite3.Row]] = {}
        for row in rows:
            by_group.setdefault(
                (str(row["source_id"]), str(row["thread_id"] or ""), str(row["actor_id"] or "")),
                [],
            ).append(row)

        def _split_header_and_body(raw_text: str) -> tuple[str, str]:
            lines = raw_text.strip().splitlines()
            hdr: list[str] = []
            idx = 0
            while idx < len(lines):
                stripped = lines[idx].strip()
                if (
                    stripped.startswith("[MoMo 同步录音转写 |")
                    or stripped.startswith("[⚠️")
                    or stripped.startswith("[日期参考：")
                    or stripped.startswith("[近期相关工单：")
                    or stripped.startswith("[说话人归属提醒：")
                ):
                    hdr.append(stripped)
                    idx += 1
                else:
                    break
            return "\n".join(hdr), "\n".join(lines[idx:]).strip()

        to_delete: list[int] = []
        to_update: list[tuple[str, int]] = []
        for (sid, _, _), group in by_group.items():
            if len(group) <= 1:
                continue
            bucket_rows: list[sqlite3.Row] = []
            bucket_lines: list[str] = []
            bucket_chars = 0
            for item in group:
                _, body = _split_header_and_body(str(item["text"] or ""))
                if not body:
                    to_delete.append(int(item["seq"]))
                    continue
                if bucket_rows and bucket_chars + len(body) + 1 > max_chars:
                    keep = bucket_rows[-1]
                    title = str(keep["title"] or sid)
                    keep_hdr, _ = _split_header_and_body(str(keep["text"] or ""))
                    hdr_block = keep_hdr or f"[MoMo 同步录音转写 | source_id={sid} | 标题={title}]"
                    merged = f"{hdr_block}\n" + "\n".join(bucket_lines)
                    to_update.append((merged, int(keep["seq"])))
                    to_delete.extend(int(r["seq"]) for r in bucket_rows[:-1])
                    bucket_rows = []
                    bucket_lines = []
                    bucket_chars = 0
                bucket_rows.append(item)
                bucket_lines.append(body)
                bucket_chars += len(body) + 1
            if len(bucket_rows) > 1:
                keep = bucket_rows[-1]
                title = str(keep["title"] or sid)
                keep_hdr, _ = _split_header_and_body(str(keep["text"] or ""))
                hdr_block = keep_hdr or f"[MoMo 同步录音转写 | source_id={sid} | 标题={title}]"
                merged = f"{hdr_block}\n" + "\n".join(bucket_lines)
                to_update.append((merged, int(keep["seq"])))
                to_delete.extend(int(r["seq"]) for r in bucket_rows[:-1])
        if not to_delete and not to_update:
            return 0
        with self.db:
            for merged_text, keep_seq in to_update:
                self.db.execute("UPDATE triggers SET text=? WHERE seq=?", (merged_text, keep_seq))
            if to_delete:
                placeholders = ",".join("?" for _ in to_delete)
                self.db.execute(f"DELETE FROM triggers WHERE seq IN ({placeholders})", to_delete)
        return len(to_delete)


class SuperAgentGateway:
    """Serves MoMo's local HTTP/SSE protocol while supervising DeepSeek SuperAgent (dsh)."""

    TRANSCRIPT_SETTLE_SECONDS = 15.0
    TRANSCRIPT_MIN_LIVE_CHARS = 120
    TRANSCRIPT_PASSAGE_CHARS = 600
    TRANSCRIPT_MAX_DEFER_SECONDS = 75.0
    TRANSCRIPT_SESSION_GAP_SECONDS = 900.0

    def __init__(
        self,
        data: Path,
        connection: dict,
        *,
        python_executable: Path,
        base_env: dict[str, str],
        manage_dsh: bool = True,
    ) -> None:
        self.data = Path(data)
        self.connection = connection
        self.python_executable = Path(python_executable)
        self.base_env = node_environment(base_env)
        self.manage_dsh = manage_dsh
        self.api_key = (self.data / "api-key").read_text(encoding="utf-8").strip()
        self.store = ProductStore(self.data / "runtime/conversation.sqlite", connection)
        self.bridge = BridgeStore(self.data / "superagent/bridge.sqlite")
        try:
            provider = load_provider(self.data, connection)
        except (ValueError, OSError):
            provider = None
        self.push = PushOutbox(
            self.store,
            connection,
            self.data / "access/devices.sqlite3",
            provider,
        )
        self.dsh_port = _allocate_loopback_port(
            {connection["port"], connection["port"] + 1, connection["port"] + 2, connection["port"] + 3}
        )
        self.bridge_secret = ""
        self.model_name = ""
        self.dsh_provider = ""
        self.dsh_ready = False
        self.dsh_error: str | None = None
        self.dsh_proc: subprocess.Popen | None = None
        self.dsh_reaper_proc: subprocess.Popen | None = None
        self._dsh_consecutive_failures = 0
        self.dsh_work_dir = self.data / "superagent/work"
        self._trigger_wakeup = asyncio.Event()
        self._run_streams: dict[str, list[asyncio.Queue]] = {}
        self._tasks: list[asyncio.Task] = []
        self._cached_tickets: list[dict] = []
        self._cached_decisions: list[dict] = []
        self._cached_state: dict = {}
        self._unsubscribed_legacy_threads: set[str] = set()
        self._source_meta_cache: dict[str, tuple[str | None, float | None]] = {}
        self._stopping = False
        self.computer = SuperAgentComputer(self.data, self._computer_ticket)

    def create_app(self) -> web.Application:
        app = web.Application(client_max_size=8 * 1024 * 1024)
        app.router.add_get("/health", self.handle_health)
        app.router.add_get("/v1/capabilities", self.handle_capabilities)
        app.router.add_get("/v1/models", self.handle_models)
        app.router.add_post("/v1/runs", self.handle_post_run)
        app.router.add_get("/v1/runs/{run_id}", self.handle_get_run)
        app.router.add_post("/v1/runs/{run_id}/stop", self.handle_stop_run)
        app.router.add_get("/momo/v1/proactive", self.handle_get_proactive)
        app.router.add_post("/momo/v1/proactive", self.handle_post_proactive)
        app.router.add_post("/momo/v1/proactive/ingest", self.handle_proactive_ingest)
        app.router.add_route("*", "/momo/v1/conversation{tail:.*}", self.handle_conversation)
        app.router.add_get("/momo/internal/superagent/triggers", self.handle_internal_triggers)
        app.router.add_get("/momo/internal/superagent/context", self.handle_internal_context)
        app.router.add_post("/momo/internal/superagent/outbound", self.handle_internal_outbound)
        app.router.add_post("/momo/internal/superagent/computer", self.handle_internal_computer)
        app.on_startup.append(self.on_startup)
        app.on_cleanup.append(self.on_cleanup)
        return app

    # ── Auth helpers ────────────────────────────────────────────────────────────

    def _check_bearer(self, request: web.Request) -> web.Response | None:
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return web.json_response({"error": {"code": "unauthorized", "message": "Missing bearer token"}}, status=401)
        provided = header[len("Bearer ") :].strip()
        if not hmac.compare_digest(provided, self.api_key):
            return web.json_response({"error": {"code": "unauthorized", "message": "Invalid bearer token"}}, status=401)
        return None

    def _check_bridge_secret(self, request: web.Request) -> web.Response | None:
        provided = request.headers.get("X-MoMo-Bridge", "").strip()
        if not self.bridge_secret or not provided or not hmac.compare_digest(provided, self.bridge_secret):
            return web.json_response({"error": "forbidden"}, status=403)
        return None

    # ── Lifecycle & dsh supervision ─────────────────────────────────────────────

    async def on_startup(self, _: web.Application) -> None:
        self._ensure_proactive_baseline()
        with suppress(Exception):
            merged = self.bridge.coalesce_unpolled_transcripts()
            if merged:
                log.info("Coalesced %d backlogged transcript micro-triggers", merged)
        self._prepare_bridge_secret()
        self._tasks.append(asyncio.create_task(self.push.run()))
        self._tasks.append(asyncio.create_task(self._watch_context_loop()))
        if self.manage_dsh:
            self._tasks.append(asyncio.create_task(self._supervise_dsh_loop()))
            self._tasks.append(asyncio.create_task(self._reconcile_dsh_loop()))

    async def on_cleanup(self, _: web.Application) -> None:
        self._stopping = True
        for task in self._tasks:
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        await asyncio.to_thread(self._stop_dsh_process)
        self.bridge.close()
        self.store.db.close()

    def _prepare_bridge_secret(self) -> None:
        state_dir = self.data / "superagent/state"
        state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        secret_file = state_dir / "momo-bridge.json"
        if secret_file.is_file():
            with suppress(ValueError, OSError):
                secret = str(json.loads(secret_file.read_text(encoding="utf-8")).get("secret") or "").strip()
                if len(secret) >= 24:
                    self.bridge_secret = secret
                    return
        self.bridge_secret = secrets.token_urlsafe(32)
        secret_file.write_text(json.dumps({"secret": self.bridge_secret}, indent=2) + "\n", encoding="utf-8")
        secret_file.chmod(0o600)

    def _ensure_proactive_baseline(self) -> None:
        """Watermark historical recordings on first boot and backfill last_recorded_at so metadata revisions never replay old spans."""
        context_dir = self.data / "context"
        already = self.bridge.db.execute("SELECT 1 FROM meta WHERE key='proactive_baseline'").fetchone()
        if not already:
            now = time.time()
            if (context_dir / "context.sqlite").is_file():
                with suppress(Exception):
                    from context_store import ContextStore

                    cstore = ContextStore(context_dir)
                    try:
                        rows = cstore.db.execute(
                            "SELECT id, revision, payload FROM sources WHERE deleted = 0"
                        ).fetchall()
                        with self.bridge.db:
                            for row in rows:
                                spans = json.loads(row["payload"]).get("spans") or []
                                max_ts = max(
                                    (float(s.get("recorded_at") or 0.0) for s in spans if isinstance(s, dict)),
                                    default=0.0,
                                )
                                self.bridge.db.execute(
                                    "INSERT OR REPLACE INTO source_watermarks(source_id, revision, max_seq, updated_at, last_recorded_at) VALUES(?,?,?,?,?)",
                                    (row["id"], row["revision"], len(spans) - 1, now, max_ts),
                                )
                    finally:
                        cstore.close()
            with self.bridge.db:
                self.bridge.db.execute("INSERT OR REPLACE INTO meta VALUES('proactive_baseline', '1')")
            if not self.store.db.execute("SELECT 1 FROM push_meta WHERE key='baseline'").fetchone():
                with self.store.db:
                    self.store.db.execute("INSERT INTO push_meta VALUES('baseline', '1')")
            return

        # Upgrade migration: populate last_recorded_at for pre-existing watermarks so diarization/summary edits never re-fire.
        missing = self.bridge.db.execute(
            "SELECT source_id FROM source_watermarks WHERE last_recorded_at <= 0 AND max_seq >= 0"
        ).fetchall()
        if missing and (context_dir / "context.sqlite").is_file():
            with suppress(Exception):
                from context_store import ContextStore

                cstore = ContextStore(context_dir)
                try:
                    updates: list[tuple[float, str]] = []
                    for mrow in missing:
                        sid = str(mrow["source_id"])
                        srow = cstore.db.execute("SELECT payload FROM sources WHERE id=?", (sid,)).fetchone()
                        if not srow:
                            continue
                        spans = json.loads(srow["payload"]).get("spans") or []
                        max_ts = max(
                            (float(s.get("recorded_at") or 0.0) for s in spans if isinstance(s, dict)),
                            default=0.0,
                        )
                        if max_ts > 0:
                            updates.append((max_ts, sid))
                    if updates:
                        with self.bridge.db:
                            self.bridge.db.executemany(
                                "UPDATE source_watermarks SET last_recorded_at=? WHERE source_id=?",
                                updates,
                            )
                finally:
                    cstore.close()

    def _dsh_pid_file(self) -> Path:
        return self.data / "superagent/dsh.pid"

    def _reclaim_stale_dsh_processes(self) -> None:
        """Terminate any orphaned `dsh --profile momo` holding session write locks for this data directory."""
        targets: dict[int, int] = {}
        runner_marker = str(self.data / "runtime/superagent")
        pid_file = self._dsh_pid_file()
        if pid_file.is_file():
            with suppress(ValueError, OSError):
                recorded = json.loads(pid_file.read_text(encoding="utf-8"))
                rec_pid = int(recorded.get("pid") or 0)
                rec_pgid = int(recorded.get("pgid") or rec_pid)
                if rec_pid > 1:
                    ps_cmd = subprocess.run(
                        ["/bin/ps", "-p", str(rec_pid), "-o", "command="],
                        capture_output=True,
                        text=True,
                    ).stdout
                    if "--profile momo" in ps_cmd and ("dsh" in ps_cmd or runner_marker in ps_cmd):
                        targets[rec_pid] = rec_pgid
            with suppress(OSError):
                pid_file.unlink()

        with suppress(Exception):
            ps_all = subprocess.run(
                ["/bin/ps", "-axo", "pid=,pgid=,command="],
                capture_output=True,
                text=True,
            ).stdout
            for raw in ps_all.splitlines():
                parts = raw.strip().split(None, 2)
                if len(parts) < 3:
                    continue
                pid_s, pgid_s, cmd = parts
                if runner_marker in cmd and "--profile momo" in cmd:
                    pid_i, pgid_i = int(pid_s), int(pgid_s)
                    if pid_i > 1 and pid_i != os.getpid():
                        targets[pid_i] = pgid_i

        if not targets:
            return
        log.info("Reclaiming %d stale dsh process(es): %s", len(targets), sorted(targets))
        for pid_i, pgid_i in targets.items():
            if pgid_i > 1:
                with suppress(ProcessLookupError, PermissionError):
                    os.killpg(pgid_i, signal.SIGTERM)
            with suppress(ProcessLookupError, PermissionError):
                os.kill(pid_i, signal.SIGTERM)
        deadline = time.monotonic() + 4.0
        while time.monotonic() < deadline:
            alive = False
            for pid_i in list(targets):
                try:
                    os.kill(pid_i, 0)
                    alive = True
                except ProcessLookupError:
                    targets.pop(pid_i, None)
                except PermissionError:
                    targets.pop(pid_i, None)
            if not alive:
                return
            time.sleep(0.1)
        for pid_i, pgid_i in list(targets.items()):
            if pgid_i > 1:
                with suppress(ProcessLookupError, PermissionError):
                    os.killpg(pgid_i, signal.SIGKILL)
            with suppress(ProcessLookupError, PermissionError):
                os.kill(pid_i, signal.SIGKILL)
        time.sleep(0.15)

    def _start_dsh_reaper(self, dsh_pid: int) -> None:
        """Spawn a tiny parent-death watchdog so SIGKILL of gateway never leaves an orphaned dsh holding session locks."""
        reaper_code = (
            "import os, signal, sys, time\n"
            "gw_pid, dsh_pid = int(sys.argv[1]), int(sys.argv[2])\n"
            "while True:\n"
            "    time.sleep(1.0)\n"
            "    try:\n"
            "        os.kill(dsh_pid, 0)\n"
            "    except ProcessLookupError:\n"
            "        sys.exit(0)\n"
            "    try:\n"
            "        os.kill(gw_pid, 0)\n"
            "    except ProcessLookupError:\n"
            "        for sig, wait_s in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 0.2)):\n"
            "            for fn in (lambda: os.killpg(dsh_pid, sig), lambda: os.kill(dsh_pid, sig)):\n"
            "                try:\n"
            "                    fn()\n"
            "                except Exception:\n"
            "                    pass\n"
            "            end = time.monotonic() + wait_s\n"
            "            while time.monotonic() < end:\n"
            "                try:\n"
            "                    os.kill(dsh_pid, 0)\n"
            "                    time.sleep(0.1)\n"
            "                except ProcessLookupError:\n"
            "                    sys.exit(0)\n"
            "        sys.exit(0)\n"
        )
        with suppress(Exception):
            self.dsh_reaper_proc = subprocess.Popen(
                [str(self.python_executable), "-I", "-c", reaper_code, str(os.getpid()), str(dsh_pid)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )

    def _start_dsh_process(self) -> dict:
        self._reclaim_stale_dsh_processes()
        try:
            dsh_bin = prepared_dsh_binary(self.data)
        except ValueError:
            prepare_superagent(self.data, self.base_env)
            dsh_bin = prepared_dsh_binary(self.data)
        instance = prepare_dsh_instance(
            self.data,
            python_executable=self.python_executable,
            dsh_port=self.dsh_port,
        )
        self.bridge_secret = instance["bridge_secret"]
        self.model_name = instance["model_id"]
        self.dsh_provider = instance["dsh_provider"]
        self.dsh_work_dir = instance["work_dir"]
        workspace_dir = self.data / "workspace"
        workspace_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        env = dict(self.base_env)
        env.update(instance["llm_env"])
        env["DSH_HOME"] = str(instance["dsh_home"])
        env["MOMO_DATA_DIR"] = str(self.data)
        env["MOMO_COMPUTER_BRIDGE"] = f"http://127.0.0.1:{self.connection['port']}"
        env["DSH_SUPERAGENT_MOMO_CLI"] = str(instance["state_dir"] / "momo-cli")
        env["DSH_SUPERAGENT_MOMO_WORKSPACE"] = str(workspace_dir)
        log_path = self.data / "superagent/dsh.log"
        log_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            proc = subprocess.Popen(
                [str(dsh_bin), "--profile", "momo"],
                cwd=str(workspace_dir),
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=log_fd,
                stderr=log_fd,
                start_new_session=True,
            )
        finally:
            os.close(log_fd)
        self.dsh_proc = proc
        with suppress(OSError):
            pid_file = self._dsh_pid_file()
            pid_file.write_text(
                json.dumps({"pid": proc.pid, "pgid": proc.pid, "gateway_pid": os.getpid()}, indent=2) + "\n",
                encoding="utf-8",
            )
            pid_file.chmod(0o600)
        self._start_dsh_reaper(proc.pid)
        return instance

    def _stop_dsh_process(self) -> None:
        reaper = self.dsh_reaper_proc
        self.dsh_reaper_proc = None
        if reaper is not None and reaper.poll() is None:
            with suppress(ProcessLookupError):
                reaper.terminate()
            with suppress(Exception):
                reaper.wait(timeout=1)
        proc = self.dsh_proc
        self.dsh_proc = None
        self.dsh_ready = False
        with suppress(OSError):
            self._dsh_pid_file().unlink()
        if proc is not None and proc.poll() is None:
            with suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                with suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL)
                with suppress(Exception):
                    proc.wait(timeout=2)

    async def _supervise_dsh_loop(self) -> None:
        while not self._stopping:
            try:
                if not self.dsh_ready or self.dsh_proc is None or self.dsh_proc.poll() is not None:
                    self.dsh_ready = False
                    await asyncio.to_thread(self._stop_dsh_process)
                    await asyncio.to_thread(self._start_dsh_process)
                    # Wait for dsh /orchestrator/api/state to come online on loopback.
                    started_ok = False
                    for _ in range(80):
                        if self._stopping or (self.dsh_proc and self.dsh_proc.poll() is not None):
                            break
                        try:
                            await asyncio.to_thread(dsh_api_request, self.dsh_port, "GET", "/orchestrator/api/state", None, 2.0)
                            started_ok = True
                            break
                        except Exception:
                            await asyncio.sleep(0.25)
                    if started_ok:
                        proactive_mode = read_engine_config(self.data)["proactive_mode"]
                        state = await asyncio.to_thread(
                            seed_superagent_orchestrator,
                            dsh_port=self.dsh_port,
                            gateway_port=self.connection["port"],
                            work_dir=self.dsh_work_dir,
                            proactive_mode=proactive_mode,
                            dsh_provider=self.dsh_provider,
                            model_id=self.model_name,
                        )
                        self._cached_state = state
                        self._dsh_consecutive_failures = 0
                        self.dsh_ready = True
                        self.dsh_error = None
                        log.info("DeepSeek SuperAgent ready on 127.0.0.1:%s (model=%s)", self.dsh_port, self.model_name)
                    else:
                        self.dsh_error = "dsh_startup_timeout"
                        await asyncio.to_thread(self._stop_dsh_process)
            except Exception as exc:
                self.dsh_ready = False
                self.dsh_error = str(exc)
                log.warning("SuperAgent supervisor cycle error: %s", exc)
                await asyncio.to_thread(self._stop_dsh_process)
            await asyncio.sleep(2.0)

    async def _reconcile_dsh_loop(self) -> None:
        while not self._stopping:
            if self.dsh_ready:
                try:
                    fetched = await asyncio.to_thread(self._fetch_dsh_snapshots)
                    runtime_state = fetched[0].get("health", {}).get("runtime", {}).get("state")
                    if runtime_state == "error":
                        raise RuntimeError(f"DSH runtime reported error state: {fetched[0].get('health', {}).get('runtime')}")
                    self._dsh_consecutive_failures = 0
                    self._apply_dsh_projections(*fetched)
                    await asyncio.to_thread(self._unsubscribe_ended_transcript_threads, fetched[1])
                    self.publish_live_state()
                except Exception as exc:
                    self._dsh_consecutive_failures += 1
                    if self._dsh_consecutive_failures >= 3:
                        log.warning("DSH health check failed %d times (%s); restarting dsh", self._dsh_consecutive_failures, exc)
                        self.dsh_ready = False
                        self.dsh_error = str(exc)
                        await asyncio.to_thread(self._stop_dsh_process)
            await asyncio.sleep(1.0)

    @staticmethod
    def _thread_keys(raw_threads: object) -> list[str]:
        if not isinstance(raw_threads, list):
            return []
        keys: list[str] = []
        for item in raw_threads:
            if isinstance(item, dict):
                k = str(item.get("key") or item.get("id") or "").strip()
                if k:
                    keys.append(k)
            elif isinstance(item, str) and item.strip():
                keys.append(item.strip())
        return keys

    @staticmethod
    def _format_dsh_reason(raw_reason: object) -> str | None:
        if isinstance(raw_reason, str):
            return raw_reason.strip() or None
        if not isinstance(raw_reason, list):
            return None
        parts: list[str] = []
        code_labels = {
            "explicitRouted": "编排器显式路由派发",
            "proactiveAccepted": "主动规则命中派发",
        }
        for item in raw_reason:
            if isinstance(item, str) and item.strip():
                parts.append(item.strip())
            elif isinstance(item, dict):
                vals = item.get("values")
                if isinstance(vals, dict):
                    txt = str(vals.get("text") or vals.get("note") or "").strip()
                    if txt:
                        parts.append(txt)
                        continue
                code = str(item.get("code") or "").strip()
                if code in code_labels:
                    parts.append(code_labels[code])
        return "；".join(parts) if parts else None

    def _unsubscribe_ended_transcript_threads(self, tickets: list[dict]) -> None:
        """Drop ended tickets' subscriptions to transcript threads so subsequent recording chunks never force-reopen ended tickets."""
        if not self.dsh_ready:
            return
        open_threads: set[str] = set()
        ended_threads: set[str] = set()
        for t in tickets:
            if not isinstance(t, dict):
                continue
            is_ended = bool(t.get("ended")) or str(t.get("state") or "") in (
                "ended",
                "completed",
                "merged",
                "dropped",
                "stopped",
                "canceled",
                "cancelled",
            )
            for th_s in self._thread_keys(t.get("threads")):
                if not th_s.startswith("momo:transcript:"):
                    continue
                if is_ended:
                    ended_threads.add(th_s)
                else:
                    open_threads.add(th_s)
        for th_s in ended_threads - open_threads - self._unsubscribed_legacy_threads:
            with suppress(Exception):
                dsh_api_request(
                    self.dsh_port,
                    "POST",
                    f"/orchestrator/api/threads/{quote(th_s, safe='')}/unsubscribe",
                    {},
                    timeout=3.0,
                )
                self._unsubscribed_legacy_threads.add(th_s)

    def _fetch_dsh_snapshots(self) -> tuple[dict, list[dict], list[dict]]:
        state = dsh_api_request(self.dsh_port, "GET", "/orchestrator/api/state", timeout=4.0)
        open_resp = dsh_api_request(self.dsh_port, "GET", "/orchestrator/api/tickets?state=open&limit=30", timeout=4.0)
        ended_resp = dsh_api_request(self.dsh_port, "GET", "/orchestrator/api/tickets?state=ended&limit=40", timeout=4.0)
        decisions_resp = dsh_api_request(self.dsh_port, "GET", "/orchestrator/api/decisions?limit=40", timeout=4.0)
        seen_ids: set[str] = set()
        tickets: list[dict] = []
        for resp in (open_resp, ended_resp):
            rows = resp.get("items", resp.get("tickets", [])) if isinstance(resp, dict) else []
            for item in rows:
                tid = item.get("id") if isinstance(item, dict) else None
                if tid and tid not in seen_ids:
                    seen_ids.add(tid)
                    tickets.append(item)
        decisions = (
            decisions_resp.get("items", decisions_resp.get("decisions", []))
            if isinstance(decisions_resp, dict)
            else []
        )
        return state, tickets, decisions

    def _apply_dsh_projections(self, state: dict, tickets: list[dict], decisions: list[dict]) -> None:
        self._cached_state = state
        self._cached_tickets = tickets
        self._cached_decisions = decisions

        decisions_by_trigger: dict[str, dict] = {}
        for dec in decisions:
            if not isinstance(dec, dict):
                continue
            raw_trigs = dec.get("triggerIds")
            if isinstance(raw_trigs, list):
                for trig in raw_trigs:
                    if isinstance(trig, str) and trig:
                        decisions_by_trigger[trig] = dec
            if isinstance(dec.get("triggerId"), str) and dec["triggerId"]:
                decisions_by_trigger[dec["triggerId"]] = dec
        tickets_by_id = {t["id"]: t for t in tickets if isinstance(t, dict) and t.get("id")}

        now = time.time()
        active_rows = self.bridge.db.execute(
            "SELECT * FROM chat_runs WHERE status IN ('queued', 'started', 'waiting_for_input')"
        ).fetchall()
        for row in active_rows:
            trig_id = row["trigger_id"]
            dec = decisions_by_trigger.get(trig_id) if trig_id else None
            ticket_id = row["ticket_id"] or (dec.get("ticketId") if dec else None)
            ticket = tickets_by_id.get(ticket_id) if ticket_id else None
            new_status = row["status"]
            wait_reason = row["wait_reason"]
            err = row["error"]
            if dec and dec.get("kind") == "ignore" and not ticket_id:
                # Allow Outbox a brief window to deliver orchestrator_reply(purpose='answer') before closing un-replied runs.
                has_reply = self.store.db.execute(
                    "SELECT 1 FROM messages WHERE run_id=? AND role='assistant' LIMIT 1",
                    (row["run_id"],),
                ).fetchone()
                if has_reply or now - float(row["updated_at"]) >= 10.0:
                    new_status = "completed"
                    wait_reason = None
            elif ticket:
                ended_info = ticket.get("ended")
                ended_outcome = (
                    str(ended_info.get("outcome") or "")
                    if isinstance(ended_info, dict)
                    else str(ended_info or "")
                )
                t_state = str(ticket.get("state") or ticket.get("outcome") or "")
                t_action = str(ticket.get("action") or "")
                if ticket.get("attention"):
                    new_status = "waiting_for_input"
                    wait_reason = "clarify"
                elif ended_outcome in ("stopped", "canceled", "cancelled") or t_state in ("stopped", "canceled", "cancelled"):
                    new_status = "cancelled"
                    wait_reason = None
                elif t_action == "failed" or ended_outcome == "failed" or t_state == "failed":
                    new_status = "failed"
                    err = "执行未完成，请核对已有结果。"
                elif ended_outcome in ("dropped",) or t_state in ("dropped",):
                    new_status = "completed"
                    wait_reason = None
            if (new_status, ticket_id, wait_reason, err) != (row["status"], row["ticket_id"], row["wait_reason"], row["error"]):
                with self.bridge.db:
                    self.bridge.db.execute(
                        """UPDATE chat_runs
                           SET status=?, ticket_id=coalesce(?, ticket_id), wait_reason=?, error=?,
                               cancellable=?, updated_at=?
                           WHERE run_id=?""",
                        (
                            new_status,
                            ticket_id,
                            wait_reason,
                            err,
                            int(new_status in ("queued", "started", "waiting_for_input")),
                            now,
                            row["run_id"],
                        ),
                    )
                if new_status in ("completed", "failed", "cancelled"):
                    self._finish_run_stream(row["run_id"], new_status)

    # ── Proactive Context Watcher ───────────────────────────────────────────────

    async def _watch_context_loop(self) -> None:
        while not self._stopping:
            with suppress(Exception):
                created = self.ingest_context_sources(settle_seconds=self.TRANSCRIPT_SETTLE_SECONDS)
                if created:
                    self._trigger_wakeup.set()
            await asyncio.sleep(1.5)

    def _recent_proactive_ticket_summaries(
        self,
        *,
        source_id: str | None = None,
        now: float | None = None,
        max_items: int = 8,
    ) -> list[dict]:
        ref_now = now if now is not None else time.time()
        items: list[dict] = []
        for t in self._cached_tickets:
            if not isinstance(t, dict) or not t.get("id"):
                continue
            tid = str(t["id"])
            ended_info = t.get("ended")
            ended_outcome = (
                str(ended_info.get("outcome") or "")
                if isinstance(ended_info, dict)
                else str(ended_info or "")
            )
            t_state = str(t.get("state") or "")
            is_ended = bool(ended_info) or t_state in (
                "ended",
                "completed",
                "merged",
                "dropped",
                "stopped",
                "canceled",
                "cancelled",
            )
            status_label = (ended_outcome or t_state or "ended") if is_ended else "open"
            updated_at = (
                self._iso_to_epoch(t.get("updatedAt"))
                or (self._iso_to_epoch(ended_info.get("at")) if isinstance(ended_info, dict) else None)
                or self._iso_to_epoch(t.get("createdAt"))
            )
            threads = self._thread_keys(t.get("threads"))
            mandate = t.get("mandate") if isinstance(t.get("mandate"), dict) else {}
            basis = mandate.get("basis") if isinstance(mandate.get("basis"), dict) else {}
            basis_scope = basis.get("scope") if isinstance(basis.get("scope"), dict) else {}
            ticket_sid = str(basis_scope.get("sourceId") or "").strip()
            if not ticket_sid:
                for th in threads:
                    clean_th = th.removeprefix("momo:")
                    if clean_th.startswith("transcript:"):
                        ticket_sid = re.split(r":[ws]\d+", clean_th.partition(":")[2], maxsplit=1)[0]
                        if ticket_sid:
                            break
            same_source = bool(source_id and ticket_sid == source_id)
            recent_enough = not is_ended or (updated_at is not None and (ref_now - updated_at) <= 12 * 3600)
            if not same_source and not recent_enough:
                continue
            scope_txt = str(mandate.get("scope") or t.get("summary") or "").strip()[:140]
            items.append(
                {
                    "id": tid,
                    "title": str(t.get("title") or tid)[:80],
                    "status": status_label,
                    "same_source": same_source,
                    **({"scope": scope_txt} if scope_txt else {}),
                }
            )
            if len(items) >= max_items:
                break
        return items

    def ingest_context_sources(self, *, settle_seconds: float = 0.0) -> list[str]:
        """Scan ContextStore for newly arrived or extended voice transcripts and enqueue coherent proactive triggers."""
        mode = read_engine_config(self.data)["proactive_mode"]
        if mode == "off":
            return []
        context_dir = self.data / "context"
        if not (context_dir / "context.sqlite").is_file():
            return []
        from context_store import ContextStore

        emitted: list[str] = []
        cstore = ContextStore(context_dir)
        try:
            sources = cstore.db.execute(
                "SELECT id, revision, payload, updated FROM sources WHERE deleted = 0 ORDER BY updated ASC"
            ).fetchall()
            now = time.time()
            for src in sources:
                sid = src["id"]
                rev = src["revision"]
                watermark = self.bridge.db.execute(
                    "SELECT revision, max_seq, updated_at, last_recorded_at FROM source_watermarks WHERE source_id=?",
                    (sid,),
                ).fetchone()
                if watermark and watermark["revision"] == rev:
                    continue
                prev_max = int(watermark["max_seq"]) if watermark else -1
                prev_last_ts = float(watermark["last_recorded_at"] or 0.0) if watermark else 0.0
                payload = json.loads(src["payload"])
                spans = payload.get("spans") or []
                if not spans:
                    with self.bridge.db:
                        self.bridge.db.execute(
                            "INSERT OR REPLACE INTO source_watermarks(source_id, revision, max_seq, updated_at, last_recorded_at) VALUES(?,?,?,?,?)",
                            (sid, rev, -1, now, prev_last_ts),
                        )
                    continue
                max_seq = len(spans) - 1
                max_span_ts = max(
                    (float(s.get("recorded_at") or 0.0) for s in spans if isinstance(s, dict)),
                    default=prev_last_ts,
                )
                has_emitted_for_source = (
                    self.bridge.db.execute("SELECT 1 FROM triggers WHERE source_id=? LIMIT 1", (sid,)).fetchone()
                    is not None
                )
                if watermark is None:
                    indexed_new = [(idx, s) for idx, s in enumerate(spans)]
                else:
                    indexed_new = [
                        (idx, s)
                        for idx, s in enumerate(spans)
                        if idx > prev_max and (prev_last_ts <= 0.0 or float(s.get("recorded_at") or 0.0) > prev_last_ts)
                    ]
                    if not indexed_new:
                        if not has_emitted_for_source and any(
                            classify_transcript_span(s)[1] is True
                            and not is_filler_only_utterance(classify_transcript_span(s)[2])
                            for s in spans
                            if isinstance(s, dict)
                        ):
                            # Live cluster-to-owner voiceprint upgrade or manual "[说话人 N] -> [我]" correction
                            # on a source that previously emitted nothing because no owner speech was recognized yet.
                            indexed_new = [(idx, s) for idx, s in enumerate(spans)]
                        else:
                            # Non-append metadata/diarization/summary revision: advance watermark silently without re-triggering!
                            with self.bridge.db:
                                self.bridge.db.execute(
                                    "INSERT OR REPLACE INTO source_watermarks(source_id, revision, max_seq, updated_at, last_recorded_at) VALUES(?,?,?,?,?)",
                                    (sid, rev, max_seq, now, max(prev_last_ts, max_span_ts)),
                                )
                            continue
                new_spans = [s for _, s in indexed_new]

                transcript_lines = []
                for span in new_spans:
                    ts = float(span.get("recorded_at") or now)
                    dt_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
                    formatted_line = format_transcript_span_line(dt_str, span)
                    if formatted_line:
                        transcript_lines.append(formatted_line)
                full_new_body = "\n".join(transcript_lines).strip()
                if not full_new_body:
                    with self.bridge.db:
                        self.bridge.db.execute(
                            "INSERT OR REPLACE INTO source_watermarks(source_id, revision, max_seq, updated_at, last_recorded_at) VALUES(?,?,?,?,?)",
                            (sid, rev, max_seq, now, max(prev_last_ts, max_span_ts)),
                        )
                    continue
                is_final = bool(
                    payload.get("ended_at")
                    or payload.get("final")
                    or payload.get("is_final")
                    or payload.get("completed")
                )
                if settle_seconds > 0 and not is_final:
                    quiet_elapsed = max(0.0, now - float(src["updated"]))
                    defer_elapsed = max(0.0, now - float(watermark["updated_at"])) if watermark else quiet_elapsed
                    needs_more_settle = quiet_elapsed < settle_seconds or (
                        len(full_new_body) < self.TRANSCRIPT_MIN_LIVE_CHARS and quiet_elapsed < 45.0
                    )
                    if (
                        needs_more_settle
                        and len(full_new_body) < self.TRANSCRIPT_PASSAGE_CHARS
                        and defer_elapsed < self.TRANSCRIPT_MAX_DEFER_SECONDS
                    ):
                        # Hold watermark while streaming ASR spans are actively arriving mid-thought.
                        continue

                # Compute deterministic conversation segments across spans by natural silence gap (>15 min)
                # so a continuous 20-40 min discussion stays on one thread while multi-hour gaps split cleanly.
                seg_by_idx: list[int] = []
                cur_seg = 0
                prev_seg_ts = 0.0
                for span_item in spans:
                    st_ts = float(span_item.get("recorded_at") or 0.0) if isinstance(span_item, dict) else 0.0
                    if prev_seg_ts > 0.0 and st_ts > 0.0 and (st_ts - prev_seg_ts) > self.TRANSCRIPT_SESSION_GAP_SECONDS:
                        cur_seg += 1
                    seg_by_idx.append(cur_seg)
                    if st_ts > 0.0:
                        prev_seg_ts = max(prev_seg_ts, st_ts)

                segment_groups: list[tuple[int, int, list[dict]]] = []
                for idx, span_item in indexed_new:
                    s_id = seg_by_idx[idx]
                    if segment_groups and segment_groups[-1][0] == s_id:
                        segment_groups[-1][2].append(span_item)
                    else:
                        segment_groups.append((s_id, idx, [span_item]))

                with self.bridge.db:
                    self.bridge.db.execute(
                        "INSERT OR REPLACE INTO source_watermarks(source_id, revision, max_seq, updated_at, last_recorded_at) VALUES(?,?,?,?,?)",
                        (sid, rev, max_seq, now, max(prev_last_ts, max_span_ts)),
                    )

                ended_threads = {
                    th_s
                    for t in self._cached_tickets
                    if isinstance(t, dict) and (t.get("ended") or t.get("state") == "ended")
                    for th_s in self._thread_keys(t.get("threads"))
                }
                live_threads = {
                    th_s
                    for t in self._cached_tickets
                    if isinstance(t, dict) and not (t.get("ended") or t.get("state") == "ended")
                    for th_s in self._thread_keys(t.get("threads"))
                }
                source_is_attributed = any(
                    classify_transcript_span(s)[1] is not None for s in spans if isinstance(s, dict)
                )
                recent_tickets = self._recent_proactive_ticket_summaries(source_id=sid, now=now, max_items=6)
                recent_ticket_note = ""
                if recent_tickets:
                    formatted_tickets = "；".join(
                        f"{rt['id']}《{rt['title']}》[{rt['status']}{',同录音' if rt.get('same_source') else ''}]"
                        for rt in recent_tickets
                    )
                    recent_ticket_note = (
                        f"[近期相关工单：{formatted_tickets}。"
                        f"若本段仅是对上述已建单/已结案事项的延续或重复讨论且无新增独立诉求，请勿重复建单。]\n"
                    )

                title = payload.get("title") or sid
                day_start_hour = read_day_start_hour(self.data)
                now_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
                today_day = logical_local_date(now, day_start_hour).isoformat()

                for seg_idx, seg_first_idx, seg_spans in segment_groups:
                    seg_lines = []
                    seg_has_substantive_owner = False
                    seg_has_other = False
                    for span in seg_spans:
                        ts = float(span.get("recorded_at") or now)
                        dt_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
                        _, spk_is_owner, spk_body = classify_transcript_span(span)
                        if not spk_body:
                            continue
                        if spk_is_owner is True:
                            if not is_filler_only_utterance(spk_body):
                                seg_has_substantive_owner = True
                        elif spk_is_owner is False:
                            seg_has_other = True
                        formatted_line = format_transcript_span_line(dt_str, span)
                        if formatted_line:
                            seg_lines.append(formatted_line)
                    body = "\n".join(seg_lines).strip()
                    if not body:
                        continue

                    base_thread = f"transcript:{sid}:s{seg_idx}"
                    candidate_thread = base_thread
                    suffix_idx = 1
                    while f"momo:{candidate_thread}" in ended_threads:
                        suffix_idx += 1
                        candidate_thread = f"{base_thread}:r{suffix_idx}"

                    if source_is_attributed or seg_has_other:
                        if not seg_has_substantive_owner:
                            # Never start proactive tasks from other speakers' utterances (e.g. colleague saying "我去 xxx").
                            # Only deliver as non-owner follow-up context when a live open ticket already subscribes to this thread.
                            if f"momo:{candidate_thread}" not in live_threads:
                                continue
                            actor_id = "other"
                            actor_name = "Other Speaker (Voice Transcript)"
                            speaker_note = (
                                "[说话人归属提醒：本段无用户本人 [我（用户本人）] 的实质发言，仅包含其他说话人发言或简短附和，"
                                "仅供当前活跃工单补充对话上下文参考，严禁据此新建工单或承接他人的任务。]\n"
                            )
                        else:
                            actor_id = "owner"
                            actor_name = "User (Voice Transcript)"
                            speaker_note = (
                                "[说话人归属提醒：本段为多人对话。仅标记为 [我（用户本人）] 的原话代表用户本人；"
                                "标记为 [他人:...] 的原话（包括其中的第一人称“我去/我来/我这边...”）均属于其他说话人自己的行为或工作，"
                                "绝不能把别人说的“我去 xxx”当成给用户建单的依据！]\n"
                                if seg_has_other
                                else ""
                            )
                    else:
                        actor_id = "owner"
                        actor_name = "User (Voice Transcript)"
                        speaker_note = ""

                    context_prefix = ""
                    if seg_first_idx > 0:
                        prior_lines = []
                        for pidx in range(max(0, seg_first_idx - 6), seg_first_idx):
                            if seg_by_idx[pidx] != seg_idx:
                                continue
                            pspan = spans[pidx]
                            pts = float(pspan.get("recorded_at") or now)
                            pdt_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(pts))
                            pline = format_transcript_span_line(pdt_str, pspan)
                            if pline:
                                prior_lines.append(pline)
                        if prior_lines:
                            prior_joined = "\n".join(prior_lines)[-520:]
                            context_prefix = f"[近期前文参考]\n{prior_joined}\n[本次新增转写]\n"

                    earliest_new_ts = min((float(s.get("recorded_at") or now) for s in seg_spans), default=now)
                    latest_span_ts = max((float(s.get("recorded_at") or now) for s in seg_spans), default=now)
                    rec_start_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(earliest_new_ts))
                    rec_end_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(latest_span_ts))
                    rec_time_label = (
                        rec_start_str if rec_start_str[:16] == rec_end_str[:16] else f"{rec_start_str} ~ {rec_end_str}"
                    )
                    rec_day = logical_local_date(latest_span_ts, day_start_hour).isoformat()
                    lag_seconds = max(0.0, now - latest_span_ts)
                    date_anchor_note = ""
                    if rec_day != today_day or lag_seconds >= 6 * 3600:
                        lag_hours = lag_seconds / 3600.0
                        sync_status = (
                            f"跨日补同步（滞后 {lag_hours:.1f} 小时，录制于 {rec_day}）"
                            if rec_day != today_day
                            else f"延迟补同步（滞后 {lag_hours:.1f} 小时）"
                        )
                        date_anchor_note = (
                            f"[日期参考：本段录音记录于 {rec_end_str}，当前时间为 {now_str}。"
                            f"录音中的“今天/明天/今晚”等相对时间请以 {rec_day} 为基准换算实际日期，"
                            f"结合事项本身的时效性与后续上下文自然判断是否仍需跟进。]\n"
                        )
                    else:
                        sync_status = "实时同步" if lag_seconds < 600 else f"当日补同步（滞后 {int(lag_seconds // 60)} 分钟）"

                    event_id = (
                        f"transcript:{sid}:{rev[:24]}"
                        if len(segment_groups) == 1
                        else f"transcript:{sid}:{rev[:24]}:s{seg_idx}"
                    )
                    trigger_id = f"momo:{event_id}"
                    text = (
                        f"[MoMo 同步录音转写 | source_id={sid} | 标题={title} | 录音时间={rec_time_label} | 当前时间={now_str} | 同步状态={sync_status}]\n"
                        f"{date_anchor_note}{recent_ticket_note}{speaker_note}{context_prefix}{body}"
                    )
                    self.bridge.enqueue_trigger(
                        trigger_id=trigger_id,
                        kind="transcripts",
                        thread_id=candidate_thread,
                        message_id=event_id,
                        source_id=sid,
                        title=title,
                        actor_id=actor_id,
                        actor_name=actor_name,
                        addressed=False,
                        human=True,
                        observed=True,
                        text=text,
                        at_iso=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(latest_span_ts)),
                    )
                    emitted.append(trigger_id)
        finally:
            cstore.close()
        return emitted

    # ── Public HTTP Endpoints ───────────────────────────────────────────────────

    async def handle_health(self, _: web.Request) -> web.Response:
        return web.json_response(
            {
                "status": "ok" if self.dsh_ready or not self.manage_dsh else "starting",
                "engine": "superagent",
                "dsh_ready": self.dsh_ready,
            }
        )

    async def handle_capabilities(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        cfg = read_engine_config(self.data)
        if not self.model_name:
            with suppress(Exception):
                self.model_name = resolve_superagent_llm(self.data)["model_id"]
        features = {
            "chat_completions": False,
            "chat_completions_streaming": False,
            "responses_api": False,
            "responses_streaming": False,
            "run_submission": True,
            "runs_idempotency": {
                "supported": True,
                "durable": True,
                "retention_seconds": BridgeStore.RETENTION_SECONDS,
            },
            "run_status": True,
            "run_events_sse": True,
            "run_stop": True,
            "run_steer": True,
            "proactive_agent": True,
        }
        return web.json_response(
            {
                "object": "hermes.api_server.capabilities",
                "platform": "deepseek-superagent",
                "engine": "superagent",
                "proactive_mode": cfg["proactive_mode"],
                "dsh_ready": self.dsh_ready,
                "upstream_commit": superagent_fingerprint()["upstream_commit"],
                "model": self.model_name,
                "auth": {"type": "bearer", "required": True},
                "runtime": {
                    "mode": "server_agent",
                    "engine": "superagent",
                    "tool_execution": "server",
                    "split_runtime": False,
                    "description": "DeepSeek SuperAgent (dsh-superagent) orchestrator + worker runtime bridged into MoMo Agent.",
                },
                "features": features,
                "endpoints": {
                    "health": {"method": "GET", "path": "/health"},
                    "runs": {"method": "POST", "path": "/v1/runs"},
                    "run_status": {"method": "GET", "path": "/v1/runs/{run_id}"},
                    "proactive": {"method": "GET", "path": "/momo/v1/proactive"},
                },
            }
        )

    async def handle_models(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        return web.json_response({"object": "list", "data": [{"id": self.model_name or "default", "object": "model"}]})

    # ── /v1/runs (Recording summary & direct background runs) ───────────────────

    async def handle_post_run(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        payload = await request.json()
        if not isinstance(payload, dict):
            return web.json_response({"error": {"code": "invalid_request", "message": "JSON object required"}}, status=400)
        prompt = str(payload.get("input") or payload.get("prompt") or "").strip()
        session_id = str(payload.get("session_id") or f"momo-run-{uuid.uuid4().hex[:12]}").strip()
        if not prompt:
            return web.json_response({"error": {"code": "invalid_request", "message": "input is required"}}, status=400)
        idem = request.headers.get("Idempotency-Key", "").strip() or None
        if idem:
            existing = self.bridge.db.execute("SELECT * FROM api_runs WHERE idempotency_key=?", (idem,)).fetchone()
            if existing:
                return web.json_response(
                    {"run_id": existing["run_id"], "session_id": existing["session_id"], "status": existing["status"]},
                    status=202,
                )
        run_id = "run_sa_" + uuid.uuid4().hex
        now = time.time()
        with self.bridge.db:
            self.bridge.db.execute(
                "INSERT INTO api_runs VALUES(?,?,?,?,?,?,?,?,?)",
                (run_id, idem, session_id, prompt, "started", None, None, now, now),
            )
        asyncio.create_task(self._execute_direct_api_run(run_id, prompt))
        return web.json_response({"run_id": run_id, "session_id": session_id, "status": "started"}, status=202)

    async def handle_get_run(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        run_id = request.match_info["run_id"]
        row = self.bridge.db.execute("SELECT * FROM api_runs WHERE run_id=?", (run_id,)).fetchone()
        if row:
            return web.json_response(
                {
                    "run_id": row["run_id"],
                    "session_id": row["session_id"],
                    "status": row["status"],
                    "output": row["output_text"],
                    "error": row["error_text"],
                }
            )
        chat_row = self.bridge.db.execute("SELECT * FROM chat_runs WHERE run_id=?", (run_id,)).fetchone()
        if chat_row:
            msg = self.store.db.execute(
                "SELECT content FROM messages WHERE run_id=? AND role='assistant' ORDER BY seq DESC LIMIT 1",
                (run_id,),
            ).fetchone()
            return web.json_response(
                {
                    "run_id": chat_row["run_id"],
                    "session_id": chat_row["session_id"],
                    "status": chat_row["status"],
                    "output": msg["content"] if msg else None,
                    "error": chat_row["error"],
                }
            )
        return web.json_response({"error": {"code": "not_found", "message": "Unknown run"}}, status=404)

    async def handle_stop_run(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        run_id = request.match_info["run_id"]
        chat_row = self.bridge.db.execute("SELECT * FROM chat_runs WHERE run_id=?", (run_id,)).fetchone()
        if chat_row and chat_row["ticket_id"] and self.dsh_ready:
            with suppress(Exception):
                await asyncio.to_thread(
                    dsh_api_request,
                    self.dsh_port,
                    "POST",
                    f"/orchestrator/api/tickets/{chat_row['ticket_id']}/stop",
                    {},
                )
        with self.bridge.db:
            self.bridge.db.execute(
                "UPDATE chat_runs SET status='cancelled', cancellable=0, cancel_requested=1, updated_at=? WHERE run_id=?",
                (time.time(), run_id),
            )
        self._finish_run_stream(run_id, "cancelled")
        return web.json_response({"run_id": run_id, "status": "cancelled"})

    async def _execute_direct_api_run(self, run_id: str, prompt: str) -> None:
        try:
            text = await asyncio.to_thread(self._call_configured_llm_oneshot, prompt)
            with self.bridge.db:
                self.bridge.db.execute(
                    "UPDATE api_runs SET status='completed', output_text=?, updated_at=? WHERE run_id=?",
                    (text, time.time(), run_id),
                )
        except Exception as exc:
            log.warning("Direct /v1/runs execution failed (%s): %s", run_id, exc)
            with self.bridge.db:
                self.bridge.db.execute(
                    "UPDATE api_runs SET status='failed', error_text='execution_failed', updated_at=? WHERE run_id=?",
                    (time.time(), run_id),
                )

    def _call_configured_llm_oneshot(self, prompt: str) -> str:
        llm = resolve_superagent_llm(self.data)
        provider = llm["dsh_provider"]
        model_id = llm["model_id"]
        if provider == "openai-codex":
            from openai import OpenAI
            from agent.codex_headers import apply_required_codex_headers
            from agent.process_bootstrap import build_keepalive_http_client

            token = llm["env"]["MOMO_LLM_API_KEY"]
            kwargs: dict = dict(api_key=token, base_url=llm["base_url"], timeout=60, max_retries=1)
            transport = build_keepalive_http_client(base_url=llm["base_url"])
            if transport is not None:
                kwargs["http_client"] = transport
            apply_required_codex_headers(kwargs, access_token=token, base_url=llm["base_url"])
            with OpenAI(**kwargs) as client:
                with client.responses.create(
                    model=model_id,
                    instructions="Follow the user prompt accurately.",
                    input=[{"role": "user", "content": prompt}],
                    store=False,
                    stream=True,
                ) as stream:
                    chunks: list[str] = []
                    for event in stream:
                        if event.type == "response.output_text.delta":
                            chunks.append(event.delta)
                    return "".join(chunks).strip()
        if provider == "anthropic":
            from agent.anthropic_adapter import build_anthropic_client, build_anthropic_kwargs
            from agent.anthropic_credentials import _is_oauth_token

            token = llm["env"].get("ANTHROPIC_OAUTH_TOKEN") or llm["env"]["MOMO_LLM_API_KEY"]
            kwargs = build_anthropic_kwargs(
                model=model_id,
                messages=[{"role": "user", "content": prompt}],
                tools=None,
                max_tokens=4096,
                reasoning_config={"enabled": False},
                is_oauth=_is_oauth_token(token),
                base_url=llm["base_url"],
            )
            with build_anthropic_client(token, llm["base_url"], timeout=60) as client:
                resp = client.messages.create(**kwargs)
            return "".join(getattr(block, "text", "") for block in resp.content).strip()

        from openai import OpenAI

        with OpenAI(api_key=llm["env"]["MOMO_LLM_API_KEY"], base_url=llm["base_url"], timeout=60) as client:
            resp = client.chat.completions.create(
                model=model_id,
                messages=[{"role": "user", "content": prompt}],
            )
            return (resp.choices[0].message.content or "").strip()

    # ── Proactive Control & Inspection Endpoints (/momo/v1/proactive*) ──────────

    async def handle_get_proactive(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        cfg = read_engine_config(self.data)
        rules: list[dict] = []
        if self.dsh_ready:
            with suppress(Exception):
                fetched = await asyncio.to_thread(self._fetch_dsh_snapshots)
                self._apply_dsh_projections(*fetched)
                settings = await asyncio.to_thread(dsh_api_request, self.dsh_port, "GET", "/orchestrator/api/settings")
                rules = settings.get("blocks", {}).get("policy", {}).get("value", {}).get("rules", [])
        return web.json_response(
            {
                "engine": cfg["engine"],
                "proactive_mode": cfg["proactive_mode"],
                "dsh_ready": self.dsh_ready,
                "dsh_port": self.dsh_port,
                "dsh_error": self.dsh_error,
                "state": self._cached_state,
                "rules": rules,
                "tickets": self._cached_tickets[:20],
                "decisions": self._cached_decisions[:20],
            }
        )

    async def handle_post_proactive(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        body = await request.json()
        if not isinstance(body, dict):
            return web.json_response({"error": {"code": "invalid_request", "message": "JSON object required"}}, status=400)
        new_mode = body.get("proactive_mode")
        if new_mode is not None:
            if new_mode not in PROACTIVE_MODES:
                return web.json_response({"error": {"code": "invalid_request", "message": "Invalid proactive_mode"}}, status=400)
            write_engine_config(self.data, proactive_mode=new_mode)
            if self.dsh_ready and new_mode in ("auto", "observe", "off"):
                def _apply_mode() -> None:
                    settings = dsh_api_request(self.dsh_port, "GET", "/orchestrator/api/settings")
                    eval_block = settings["blocks"]["eval"]
                    val = dict(eval_block["value"])
                    val["mode"] = new_mode
                    dsh_api_request(
                        self.dsh_port,
                        "PUT",
                        "/orchestrator/api/settings/eval",
                        {"revision": eval_block["revision"], "value": val},
                    )
                await asyncio.to_thread(_apply_mode)
        if isinstance(body.get("rules"), list) and self.dsh_ready:
            rules_payload = body["rules"]
            def _apply_rules() -> None:
                settings = dsh_api_request(self.dsh_port, "GET", "/orchestrator/api/settings")
                policy_block = settings["blocks"]["policy"]
                val = dict(policy_block["value"])
                val["rules"] = rules_payload
                dsh_api_request(
                    self.dsh_port,
                    "PUT",
                    "/orchestrator/api/settings/policy",
                    {"revision": policy_block["revision"], "value": val},
                )
            await asyncio.to_thread(_apply_rules)
        if body.get("stop_ticket_id") and self.dsh_ready:
            tid = str(body["stop_ticket_id"])
            await asyncio.to_thread(dsh_api_request, self.dsh_port, "POST", f"/orchestrator/api/tickets/{tid}/stop", {})
        if body.get("requeue_trigger_id") and self.dsh_ready:
            trig = str(body["requeue_trigger_id"])
            await asyncio.to_thread(dsh_api_request, self.dsh_port, "POST", f"/orchestrator/api/triggers/{trig}/requeue", {})
        return await self.handle_get_proactive(request)

    async def handle_proactive_ingest(self, request: web.Request) -> web.Response:
        if refused := self._check_bearer(request):
            return refused
        payload = {}
        if request.can_read_body:
            with suppress(Exception):
                payload = await request.json()
        is_sync_ping = isinstance(payload, dict) and payload.get("origin") == "source_sync" and not payload.get("flush")
        settle = self.TRANSCRIPT_SETTLE_SECONDS if is_sync_ping else 0.0
        created = self.ingest_context_sources(settle_seconds=settle)
        if isinstance(payload, dict) and str(payload.get("text") or "").strip():
            kind = payload.get("kind") if payload.get("kind") in ("transcripts", "life_signals") else "life_signals"
            raw_sig = str(payload.get("id") or f"signal:{uuid.uuid4().hex[:12]}")
            event_id = raw_sig[len("momo:") :] if raw_sig.startswith("momo:") else raw_sig
            sig_id = f"momo:{event_id}"
            thread_id = str(payload.get("thread_id") or f"signal:{event_id}")
            self.bridge.enqueue_trigger(
                trigger_id=sig_id,
                kind=kind,
                thread_id=thread_id,
                message_id=event_id,
                source_id=payload.get("source_id"),
                title=str(payload.get("title") or "").strip() or None,
                actor_id="owner",
                actor_name="User (Life Signal)",
                addressed=False,
                human=True,
                observed=True,
                text=str(payload["text"]).strip(),
            )
            created.append(sig_id)
        if created:
            self._trigger_wakeup.set()
        return web.json_response({"ingested": created, "count": len(created)})

    # ── Shared Conversation Endpoints (/momo/v1/conversation*) ──────────────────

    def _validate_attachments(self, raw):
        if raw is None:
            return None
        if not isinstance(raw, list) or not 1 <= len(raw) <= 4:
            raise ValueError("Invalid attachments")
        seen = set()
        total_text = 0
        result = []
        for item in raw:
            if not isinstance(item, dict):
                raise ValueError("Invalid attachment")
            ident = str(uuid.UUID(str(item.get("id", ""))))
            if ident in seen:
                raise ValueError("Duplicate attachment ID")
            seen.add(ident)
            name = item.get("name", "")
            kind = item.get("kind", "")
            media_type = item.get("media_type") or item.get("mediaType") or ""
            byte_count = item.get("byte_count") if "byte_count" in item else item.get("byteCount")
            if (
                not isinstance(name, str)
                or not name
                or len(name.encode()) > 256
                or any(c in name for c in ("\n", "\r", "\0"))
                or kind not in ("image", "document")
                or not isinstance(media_type, str)
                or type(byte_count) is not int
                or byte_count <= 0
            ):
                raise ValueError("Invalid attachment metadata")
            normalized = {
                "id": ident,
                "name": name,
                "kind": kind,
                "media_type": media_type,
                "byte_count": byte_count,
            }
            preview = item.get("preview")
            if preview is not None:
                if not isinstance(preview, str) or len(base64.b64decode(preview, validate=True)) > 64_000:
                    raise ValueError("Invalid attachment preview")
                normalized["preview"] = preview
            if kind == "image":
                data = item.get("data")
                if media_type not in ("image/jpeg", "image/png") or not isinstance(data, str) or item.get("text") is not None:
                    raise ValueError("Invalid image attachment")
                decoded = base64.b64decode(data, validate=True)
                if not decoded or len(decoded) > 1_048_576:
                    raise ValueError("Image attachment too large")
                normalized["data"] = data
            else:
                text = item.get("text")
                if item.get("data") is not None or not isinstance(text, str) or not text.strip():
                    raise ValueError("Invalid document attachment")
                encoded_len = len(text.encode())
                total_text += encoded_len
                if encoded_len > 256_000 or total_text > 256_000:
                    raise ValueError("Document attachment text too large")
                normalized["text"] = text
            result.append(normalized)
        return result

    def _project_chat_run(self, row: sqlite3.Row | dict) -> dict:
        item = dict(row)
        raw_status = item["status"]
        projected_status = "running" if raw_status == "started" else raw_status
        return {
            "run_id": item["run_id"],
            "session_id": item["session_id"],
            "execution_session_id": item["ticket_id"] or item["session_id"],
            "work_id": item["work_id"],
            "title": item["title"],
            "origin_run_id": item["run_id"],
            "status": projected_status,
            "execution_generation": item["execution_generation"],
            "wait_reason": item["wait_reason"],
            "cancellable": bool(item["cancellable"]) and raw_status in ("queued", "started", "waiting_for_input"),
            "cancel_requested": bool(item["cancel_requested"]),
            "delivery_state": item["delivery_state"],
            "pending_controls": [],
            "blocking_work_id": None,
            **({"error": item["error"]} if item.get("error") else {}),
        }

    @staticmethod
    def _iso_to_epoch(raw: object) -> float | None:
        if isinstance(raw, (int, float)):
            val = float(raw)
            return val / 1000.0 if val > 1e11 else val
        if not isinstance(raw, str) or not raw.strip():
            return None
        with suppress(ValueError):
            return datetime.fromisoformat(raw.strip().replace("Z", "+00:00")).timestamp()
        return None

    def _lookup_source_meta(self, source_id: str) -> tuple[str | None, float | None]:
        if not source_id:
            return None, None
        if source_id in self._source_meta_cache:
            return self._source_meta_cache[source_id]
        context_db = self.data / "context/context.sqlite"
        if not context_db.is_file():
            return None, None
        title: str | None = None
        recorded_at: float | None = None
        with suppress(Exception):
            conn = sqlite3.connect(context_db, timeout=3)
            try:
                row = conn.execute("SELECT payload FROM sources WHERE id=? AND deleted=0", (source_id,)).fetchone()
                if row and row[0]:
                    payload = json.loads(row[0])
                    raw_title = str(payload.get("title") or "").strip()
                    title = raw_title or None
                    spans = payload.get("spans") or []
                    span_ts = max(
                        (float(s.get("recorded_at") or 0.0) for s in spans if isinstance(s, dict)),
                        default=0.0,
                    )
                    if span_ts > 0:
                        recorded_at = span_ts
                    elif payload.get("recorded_at"):
                        recorded_at = float(payload["recorded_at"])
            finally:
                conn.close()
        if title is not None or recorded_at is not None:
            self._source_meta_cache[source_id] = (title, recorded_at)
        return title, recorded_at

    @staticmethod
    def _clean_trigger_excerpt(raw_text: str | None) -> str | None:
        if not raw_text:
            return None
        kept: list[str] = []
        in_prior = False
        for line in raw_text.splitlines():
            s = line.strip()
            if not s:
                continue
            if (
                s.startswith("[MoMo 同步录音转写 |")
                or s.startswith("[⚠️")
                or s.startswith("[日期参考：")
                or s.startswith("[近期相关工单：")
                or s.startswith("[说话人归属提醒：")
            ):
                continue
            if s == "[近期前文参考]":
                in_prior = True
                continue
            if s == "[本次新增转写]":
                in_prior = False
                continue
            if not in_prior:
                kept.append(s)
        if not kept:
            for line in raw_text.splitlines():
                s = line.strip()
                if (
                    s
                    and not s.startswith("[MoMo 同步录音转写 |")
                    and not s.startswith("[⚠️")
                    and not s.startswith("[日期参考：")
                    and not s.startswith("[近期相关工单：")
                    and not s.startswith("[说话人归属提醒：")
                    and s not in ("[近期前文参考]", "[本次新增转写]")
                ):
                    kept.append(s)
        joined = "\n".join(kept).strip()
        return joined[:380] if joined else None

    def _ticket_origin_and_source(
        self, ticket: dict, *, linked_run: sqlite3.Row | None = None
    ) -> tuple[str, str, str | None, str | None, float | None, str | None]:
        tid = str(ticket.get("id") or "")
        threads = self._thread_keys(ticket.get("threads"))
        mandate = ticket.get("mandate") if isinstance(ticket.get("mandate"), dict) else {}
        basis = mandate.get("basis") if isinstance(mandate.get("basis"), dict) else {}
        if isinstance(basis.get("thread"), str) and basis["thread"].strip():
            threads.append(basis["thread"].strip())
        basis_scope = basis.get("scope") if isinstance(basis.get("scope"), dict) else {}
        if isinstance(basis_scope.get("threadId"), str) and basis_scope["threadId"].strip():
            threads.append(basis_scope["threadId"].strip())

        trigger_ids: list[str] = []
        if isinstance(basis.get("triggerId"), str) and basis["triggerId"].strip():
            trigger_ids.append(basis["triggerId"].strip())
        if isinstance(basis_scope.get("messageId"), str) and basis_scope["messageId"].strip():
            trigger_ids.append(basis_scope["messageId"].strip())
        dec = ticket.get("decision") if isinstance(ticket.get("decision"), dict) else None
        if dec is None and tid:
            dec = next((d for d in self._cached_decisions if isinstance(d, dict) and d.get("ticketId") == tid), None)
        if isinstance(dec, dict):
            if isinstance(dec.get("thread"), str) and dec["thread"].strip():
                threads.append(dec["thread"].strip())
            raw_dec_trigs = dec.get("triggerIds")
            if isinstance(raw_dec_trigs, list):
                for trig_id in raw_dec_trigs:
                    if isinstance(trig_id, str) and trig_id.strip():
                        trigger_ids.append(trig_id.strip())
            if isinstance(dec.get("triggerId"), str) and dec["triggerId"].strip():
                trigger_ids.append(dec["triggerId"].strip())
        raw_inputs = ticket.get("inputs")
        if isinstance(raw_inputs, list):
            for inp in reversed(raw_inputs):
                if isinstance(inp, dict) and isinstance(inp.get("triggerId"), str) and inp["triggerId"].strip():
                    trigger_ids.append(inp["triggerId"].strip())
        if linked_run and linked_run["trigger_id"]:
            trigger_ids.append(str(linked_run["trigger_id"]))

        trig_row: sqlite3.Row | None = None
        for cand in trigger_ids:
            lookup = cand if cand.startswith("momo:") else f"momo:{cand}"
            trig_row = self.bridge.db.execute(
                "SELECT * FROM triggers WHERE id=? OR message_id=? ORDER BY seq DESC LIMIT 1",
                (lookup, cand.removeprefix("momo:")),
            ).fetchone()
            if trig_row is not None:
                break

        source_id: str | None = str(trig_row["source_id"]) if trig_row and trig_row["source_id"] else None
        if not source_id and isinstance(basis_scope.get("sourceId"), str) and basis_scope["sourceId"].strip():
            source_id = basis_scope["sourceId"].strip()
        if not source_id:
            for th in threads:
                clean_th = th.removeprefix("momo:")
                if clean_th.startswith("transcript:"):
                    raw_sid = re.split(r":[ws]\d+", clean_th.partition(":")[2], maxsplit=1)[0]
                    if raw_sid:
                        source_id = raw_sid
                        break

        is_transcript = (
            bool(source_id)
            or (trig_row is not None and trig_row["kind"] == "transcripts")
            or basis_scope.get("stream") == "transcripts"
            or any(th.removeprefix("momo:").startswith("transcript:") for th in threads)
        )
        is_signal = (
            (trig_row is not None and trig_row["kind"] == "life_signals")
            or basis_scope.get("stream") == "life_signals"
            or any(th.removeprefix("momo:").startswith("signal:") for th in threads)
        )
        if is_transcript:
            origin_kind, origin_label = "proactive_transcript", "录音主动派发"
        elif is_signal:
            origin_kind, origin_label = "proactive_signal", "生活信号派发"
        elif str(ticket.get("strength") or "") == "inferred" and not linked_run:
            origin_kind, origin_label = "proactive_transcript", "主动跟进派发"
        else:
            origin_kind, origin_label = "chat", "对话派发"

        src_title, src_rec_at = self._lookup_source_meta(source_id) if source_id else (None, None)
        trig_title = str(trig_row["title"]).strip() if trig_row and trig_row["title"] else None
        if trig_title and source_id and trig_title == source_id:
            trig_title = None
        source_title = src_title or trig_title

        source_recorded_at: float | None = None
        if trig_row and trig_row["kind"] == "transcripts":
            txt = str(trig_row["text"] or "")
            full_matches = re.findall(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]", txt)
            if full_matches:
                with suppress(ValueError):
                    source_recorded_at = time.mktime(time.strptime(full_matches[-1], "%Y-%m-%d %H:%M:%S"))
            elif src_rec_at is not None:
                hms_matches = re.findall(r"\[(\d{2}:\d{2}:\d{2})\]", txt)
                if hms_matches:
                    base_day = datetime.fromtimestamp(src_rec_at).strftime("%Y-%m-%d")
                    with suppress(ValueError):
                        source_recorded_at = time.mktime(
                            time.strptime(f"{base_day} {hms_matches[-1]}", "%Y-%m-%d %H:%M:%S")
                        )
        if source_recorded_at is None:
            source_recorded_at = src_rec_at
        if source_recorded_at is None and trig_row and trig_row["kind"] == "transcripts":
            source_recorded_at = self._iso_to_epoch(trig_row["at_iso"])

        raw_preview: str | None = None
        if trig_row and trig_row["text"]:
            raw_preview = str(trig_row["text"])
        elif isinstance(dec, dict):
            direction = dec.get("direction")
            if isinstance(direction, dict) and isinstance(direction.get("evidence"), str) and direction["evidence"].strip():
                raw_preview = direction["evidence"].strip()
            elif isinstance(dec.get("preview"), str) and dec["preview"].strip():
                raw_preview = dec["preview"].strip()
        trigger_preview = self._clean_trigger_excerpt(raw_preview)
        return origin_kind, origin_label, source_id, source_title, source_recorded_at, trigger_preview

    def _project_ticket_work(self, ticket: dict, *, allow_ended: bool) -> dict | None:
        tid = str(ticket.get("id") or "")
        if not tid:
            return None
        t_state = str(ticket.get("state") or "")
        t_stage = str(ticket.get("stage") or "")
        t_action = str(ticket.get("action") or "")
        ended_info = ticket.get("ended")
        ended_outcome = (
            str(ended_info.get("outcome") or "")
            if isinstance(ended_info, dict)
            else str(ended_info or "")
        )
        is_ended = (
            bool(ended_info)
            or t_state in ("ended", "completed", "merged", "dropped", "stopped", "canceled", "cancelled")
            or t_stage == "ended"
        )
        if is_ended and not allow_ended:
            return None
        if not is_ended and allow_ended:
            return None

        linked = self.bridge.db.execute(
            "SELECT run_id, work_id, trigger_id FROM chat_runs WHERE ticket_id=? ORDER BY seq DESC LIMIT 1",
            (tid,),
        ).fetchone()
        strength = str(ticket.get("strength") or "")
        is_proactive = strength == "inferred" or (not linked and strength != "explicit")
        if not is_ended and is_proactive and t_stage == "person" and t_action in ("blocked", "failed") and not ticket.get("attention"):
            return None

        if is_ended:
            outcome = ended_outcome or t_state
            if outcome in ("dropped",):
                mapped_state = "dropped"
                native_state = "proactive:dropped" if is_proactive else "dropped"
            elif outcome in ("stopped", "canceled", "cancelled"):
                mapped_state = "cancelled"
                native_state = "stopped"
            elif outcome in ("failed",):
                mapped_state = "failed"
                native_state = "failed"
            else:
                mapped_state = "completed"
                native_state = "proactive:completed" if is_proactive else "completed"
            cancellable = False
        else:
            if t_stage == "working" and t_action == "queued":
                mapped_state = "queued"
                native_state = "proactive:queued" if is_proactive else "queued"
            elif t_stage == "person" and t_action in ("blocked", "failed", "delivery"):
                mapped_state = "running" if t_action == "delivery" else "failed"
                native_state = f"person:{t_action}"
            elif t_stage == "person" and t_action == "review":
                mapped_state = "finalizing"
                native_state = "proactive:delivering" if is_proactive else "delivering"
            else:
                mapped_state = "running"
                native_state = f"proactive:{t_stage or 'working'}" if is_proactive else (t_stage or "working")
            actions = ticket.get("actions") if isinstance(ticket.get("actions"), dict) else {}
            cancellable = bool(actions.get("stop", True))

        origin_kind, origin_label, _, _, source_recorded_at, _ = self._ticket_origin_and_source(
            ticket, linked_run=linked
        )
        created_at = self._iso_to_epoch(ticket.get("createdAt"))
        ended_at = self._iso_to_epoch(ended_info.get("at")) if isinstance(ended_info, dict) else None
        updated_at = self._iso_to_epoch(ticket.get("updatedAt")) or ended_at or created_at
        raw_summary = str(ticket.get("summary") or "").strip() or None
        raw_assignments = ticket.get("assignments")
        if not raw_summary and isinstance(raw_assignments, list):
            for assign in reversed(raw_assignments):
                if isinstance(assign, dict) and isinstance(assign.get("report"), dict):
                    rep_sum = str(assign["report"].get("summary") or "").strip()
                    if rep_sum:
                        raw_summary = rep_sum[:240]
                        break
        if not raw_summary and isinstance(ended_info, dict) and ended_info.get("reason"):
            raw_summary = str(ended_info["reason"]).strip()[:240] or None

        return {
            "id": f"superagent:{tid}",
            "kind": "delegation",
            "work_id": linked["work_id"] if linked else f"proactive-{tid}",
            "origin_run_id": linked["run_id"] if linked else None,
            "title": str(ticket.get("title") or tid)[:80],
            "execution_generation": 1,
            "state": mapped_state,
            "native_state": native_state,
            "report_state": (
                "reported"
                if is_ended
                else (
                    "failed"
                    if t_action == "delivery"
                    else ("blocked" if t_action == "blocked" else "pending")
                )
            ),
            "wait_reason": None if is_ended else ("clarify" if ticket.get("attention") or t_action == "answer" else None),
            "blocking_work_id": None,
            "report_retry_available": False,
            "cancellable": cancellable,
            "cancel_requested": False,
            "cancel_state": None,
            "created_at": created_at,
            "updated_at": updated_at,
            "source_recorded_at": source_recorded_at,
            "origin_kind": origin_kind,
            "origin_label": origin_label,
            "summary": raw_summary,
        }

    def background_work(self) -> list[dict]:
        items: list[dict] = []
        for ticket in self._cached_tickets:
            if not isinstance(ticket, dict):
                continue
            projected = self._project_ticket_work(ticket, allow_ended=False)
            if projected is not None:
                items.append(projected)
        return items

    def _ended_work_items(self) -> list[dict]:
        items: list[dict] = []
        for ticket in self._cached_tickets:
            if not isinstance(ticket, dict):
                continue
            projected = self._project_ticket_work(ticket, allow_ended=True)
            if projected is not None:
                items.append(projected)
        items.sort(key=lambda w: float(w.get("updated_at") or w.get("created_at") or 0.0), reverse=True)
        return items

    def recent_work(self, limit: int = 15) -> list[dict]:
        items = [w for w in self._ended_work_items() if w.get("state") != "dropped"]
        return items[: max(1, min(50, limit))]

    def skipped_work(self, limit: int = 15) -> list[dict]:
        items = [w for w in self._ended_work_items() if w.get("state") == "dropped"]
        return items[: max(1, min(50, limit))]

    @staticmethod
    def _decompress_zstd_lines(raw: bytes) -> list[str]:
        from compression import zstd

        out = bytearray()
        mv = memoryview(raw)
        pos = 0
        while pos < len(mv):
            dec = zstd.ZstdDecompressor()
            try:
                out.extend(dec.decompress(mv[pos:]))
            except Exception:
                break
            if not dec.eof:
                break
            consumed = len(mv[pos:]) - len(dec.unused_data)
            if consumed <= 0:
                break
            pos += consumed
        return out.decode("utf-8", errors="replace").splitlines()

    def _parse_worker_session(
        self, ticket_id: str, *, is_active: bool
    ) -> tuple[int, int, str | None, list[dict], list[dict]]:
        if not ticket_id or "/" in ticket_id or ".." in ticket_id:
            return 0, 0, None, [], []
        sessions_root = self.data / "superagent/dsh-home/sessions"
        if not sessions_root.is_dir():
            return 0, 0, None, [], []
        candidates = sorted(sessions_root.glob(f"**/worker-{ticket_id}/session.v4.jsonl.zstd"))
        is_compressed = True
        if not candidates:
            candidates = sorted(sessions_root.glob(f"**/worker-{ticket_id}/session.v4.jsonl"))
            is_compressed = False
        if not candidates:
            return 0, 0, None, [], []

        session_file = candidates[-1]
        try:
            raw_bytes = session_file.read_bytes()
            lines = (
                self._decompress_zstd_lines(raw_bytes)
                if is_compressed
                else raw_bytes.decode("utf-8", errors="replace").splitlines()
            )
        except Exception:
            return 0, 0, None, [], []

        turn_count = 0
        step_count = 0
        cwd_path: str | None = None
        todos: list[dict] = []
        activities: list[dict] = []
        by_call_id: dict[str, dict] = {}
        cli_path = str(self.data / "superagent/state/momo-cli")

        for ln in lines:
            if not ln.strip():
                continue
            try:
                ev = json.loads(ln)
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            ev_type = str(ev.get("type") or "")
            ts_ms = ev.get("time") or ev.get("createdAt")
            ts_sec = (float(ts_ms) / 1000.0) if isinstance(ts_ms, (int, float)) and ts_ms > 1e11 else (
                float(ts_ms) if isinstance(ts_ms, (int, float)) else None
            )
            data = ev.get("data") if isinstance(ev.get("data"), dict) else {}

            if ev_type == "session":
                if ev.get("cwd"):
                    cwd_path = str(ev["cwd"])
            elif ev_type == "turn/start":
                turn_count += 1
            elif ev_type == "step/start":
                step_count += 1
            elif ev_type == "assistant/message":
                msg = data.get("message") if isinstance(data.get("message"), dict) else {}
                for block in msg.get("content") or ():
                    if isinstance(block, dict) and block.get("type") == "text":
                        txt = " ".join(str(block.get("text") or "").split()).strip()
                        if txt:
                            activities.append(
                                {
                                    "id": f"msg-{ev.get('seq', len(activities))}",
                                    "kind": "thought",
                                    "title": txt[:76] + ("…" if len(txt) > 76 else ""),
                                    "detail": txt[:260] if len(txt) > 76 else None,
                                    "status": "completed",
                                    "timestamp": ts_sec,
                                }
                            )
            elif ev_type == "tool/call":
                call_id = str(data.get("callId") or f"call-{ev.get('seq', len(activities))}")
                name = str(data.get("name") or "tool")
                raw_args = data.get("arguments")
                if isinstance(raw_args, str):
                    try:
                        args = json.loads(raw_args)
                    except ValueError:
                        args = {}
                elif isinstance(raw_args, dict):
                    args = raw_args
                else:
                    args = {}
                if not isinstance(args, dict):
                    args = {}

                if name == "skill":
                    continue
                if name == "todo_write":
                    raw_todos = args.get("todos")
                    if isinstance(raw_todos, list):
                        parsed_todos: list[dict] = []
                        for idx, td in enumerate(raw_todos):
                            if isinstance(td, dict) and td.get("content"):
                                parsed_todos.append(
                                    {
                                        "id": str(td.get("id") or f"todo-{idx}"),
                                        "content": str(td["content"]),
                                        "status": str(td.get("status") or "pending"),
                                    }
                                )
                        if parsed_todos:
                            todos = parsed_todos
                    continue

                kind = "tool"
                title = f"调用工具 {name}"
                detail: str | None = None
                if name == "bash":
                    desc = " ".join(str(args.get("description") or "").split()).strip()
                    cmd = " ".join(str(args.get("command") or "").split()).strip()
                    if cli_path:
                        cmd = cmd.replace(f'"{cli_path}"', "momo-cli").replace(cli_path, "momo-cli")
                    cmd = cmd.replace('"$DSH_SUPERAGENT_MOMO_CLI"', "momo-cli")
                    title = desc or (f"运行命令：{cmd[:48]}" if cmd else "执行终端命令")
                    detail = cmd[:180] if cmd else None
                elif name in ("read", "write", "edit", "multi_edit"):
                    fp = str(args.get("file_path") or args.get("path") or "").strip()
                    verb = "读取文件" if name == "read" else ("写入文件" if name == "write" else "修改文件")
                    fname = Path(fp).name if fp else ""
                    title = f"{verb} {fname}" if fname else verb
                    detail = fp[-160:] if fp else None
                elif name in ("glob", "grep"):
                    pat = str(args.get("pattern") or "").strip()
                    base = str(args.get("path") or "").strip()
                    verb = "查找文件" if name == "glob" else "检索内容"
                    title = f"{verb} {pat[:56]}" if pat else verb
                    detail = base[-140:] if base else None
                elif name in ("subagent", "task", "delegate"):
                    kind = "subagent"
                    role = str(
                        args.get("role")
                        or args.get("agent")
                        or args.get("subagent_type")
                        or args.get("description")
                        or "子智能体"
                    ).strip()
                    prompt_preview = " ".join(str(args.get("prompt") or args.get("task") or "").split()).strip()
                    title = f"派发子任务：{role[:52]}"
                    detail = prompt_preview[:200] if prompt_preview else None
                elif name == "orchestrator_read":
                    res = str(args.get("resource") or "").strip()
                    title = f"读取上下文 {res[:48]}" if res else "读取上下文"
                elif name == "orchestrator_reply":
                    kind = "report"
                    purpose = str(args.get("purpose") or "result")
                    msg_txt = " ".join(str(args.get("message") or args.get("text") or "").split()).strip()
                    title = "向你发起确认提问" if purpose == "attention" else "向对话发送回复"
                    detail = msg_txt[:220] if msg_txt else None
                elif name == "orchestrator_report":
                    kind = "report"
                    rep_state = str(args.get("state") or "")
                    rep_sum = " ".join(str(args.get("summary") or "").split()).strip()
                    label_map = {
                        "ready": "提交任务完成结论",
                        "dropped": "核查后静默跳过",
                        "waiting": "阶段性汇报并等待",
                        "blocked": "汇报任务受阻",
                        "failed": "汇报执行失败",
                    }
                    title = label_map.get(rep_state, f"汇报任务状态 ({rep_state})")
                    detail = rep_sum[:240] if rep_sum else None
                elif name in ("orchestrator_trigger_handback", "orchestrator_thread_unrelated"):
                    kind = "report"
                    title = "退回无关触发片段"
                    reason = " ".join(str(args.get("reason") or "").split()).strip()
                    detail = reason[:180] if reason else None
                elif name in ("job_output", "job_kill"):
                    title = "查看后台命令输出" if name == "job_output" else "终止后台命令"
                    detail = str(args.get("job_id") or "") or None
                elif args:
                    detail = json.dumps(args, ensure_ascii=False)[:160]

                item = {
                    "id": call_id,
                    "kind": kind,
                    "title": title,
                    "detail": detail,
                    "status": "running",
                    "timestamp": ts_sec,
                }
                activities.append(item)
                by_call_id[call_id] = item
            elif ev_type == "tool/result":
                msg = data.get("message") if isinstance(data.get("message"), dict) else {}
                src = msg.get("source") if isinstance(msg.get("source"), dict) else {}
                call_id = str(msg.get("toolCallId") or src.get("callId") or "")
                target_item = by_call_id.get(call_id)
                if target_item is not None:
                    is_err = bool(msg.get("isError"))
                    target_item["status"] = "failed" if is_err else "completed"

        if not is_active:
            for act in activities:
                if act["status"] == "running":
                    act["status"] = "completed"

        return turn_count, step_count, cwd_path, todos, activities[-40:]

    def _build_work_detail(self, ident: str) -> dict | None:
        ticket_id: str | None = None
        if ident.startswith("superagent:"):
            ticket_id = ident.removeprefix("superagent:")
        elif ident.startswith("proactive-"):
            ticket_id = ident.removeprefix("proactive-")

        run_row = self.bridge.db.execute(
            "SELECT * FROM chat_runs WHERE work_id=? OR run_id=? OR (ticket_id IS NOT NULL AND ticket_id=?) ORDER BY seq DESC LIMIT 1",
            (ident, ident, ticket_id or ident),
        ).fetchone()
        if run_row and run_row["ticket_id"]:
            ticket_id = str(run_row["ticket_id"])
        elif ticket_id is None and run_row is None:
            ticket_id = ident

        detail_ticket: dict | None = None
        if ticket_id:
            if self.dsh_ready:
                with suppress(Exception):
                    fetched_detail = dsh_api_request(
                        self.dsh_port,
                        "GET",
                        f"/orchestrator/api/tickets/{quote(ticket_id, safe='')}",
                        timeout=4.0,
                    )
                    if isinstance(fetched_detail, dict) and fetched_detail.get("id"):
                        detail_ticket = fetched_detail
            if detail_ticket is None:
                detail_ticket = next(
                    (t for t in self._cached_tickets if isinstance(t, dict) and str(t.get("id")) == ticket_id),
                    None,
                )

        if detail_ticket is None and run_row is None:
            return None

        if detail_ticket is not None:
            tid = str(detail_ticket.get("id") or ticket_id or "")
            projected = self._project_ticket_work(detail_ticket, allow_ended=False) or self._project_ticket_work(
                detail_ticket, allow_ended=True
            )
            status = projected["state"] if projected else "running"
            is_active = status in ("queued", "running", "waiting_for_input", "finalizing")
            cancellable = bool(projected["cancellable"]) if projected else False
            origin_kind, origin_label, source_id, source_title, source_recorded_at, trigger_preview = (
                self._ticket_origin_and_source(detail_ticket, linked_run=run_row)
            )
            ended_info = detail_ticket.get("ended") if isinstance(detail_ticket.get("ended"), dict) else {}
            created_at = self._iso_to_epoch(detail_ticket.get("createdAt"))
            ended_at = self._iso_to_epoch(ended_info.get("at"))
            updated_at = self._iso_to_epoch(detail_ticket.get("updatedAt")) or ended_at or created_at

            mandate = detail_ticket.get("mandate") if isinstance(detail_ticket.get("mandate"), dict) else {}
            decision = detail_ticket.get("decision") if isinstance(detail_ticket.get("decision"), dict) else {}
            raw_mandate_scope = mandate.get("scope")
            scope = raw_mandate_scope.strip() if isinstance(raw_mandate_scope, str) and raw_mandate_scope.strip() else None
            if not scope:
                inputs_list = detail_ticket.get("inputs")
                if isinstance(inputs_list, list):
                    for inp in reversed(inputs_list):
                        if isinstance(inp, dict) and isinstance(inp.get("note"), str) and inp["note"].strip():
                            scope = inp["note"].strip()
                            break
            if not scope and isinstance(decision.get("direction"), dict):
                ev = decision["direction"].get("evidence")
                if isinstance(ev, str) and ev.strip():
                    scope = ev.strip()
            if not scope:
                scope = self._format_dsh_reason(decision.get("reason"))

            matched_rules: list[str] = []
            raw_rules = decision.get("rules")
            if isinstance(raw_rules, list):
                for r in raw_rules:
                    if isinstance(r, dict) and r.get("matched"):
                        rname = str(r.get("name") or r.get("id") or "").strip()
                        if rname and rname not in matched_rules:
                            matched_rules.append(rname)

            summary = str(detail_ticket.get("summary") or "").strip() or None
            raw_assignments = detail_ticket.get("assignments")
            if not summary and isinstance(raw_assignments, list):
                for assign in reversed(raw_assignments):
                    if isinstance(assign, dict) and isinstance(assign.get("report"), dict):
                        rep_sum = str(assign["report"].get("summary") or "").strip()
                        if rep_sum:
                            summary = rep_sum
                            break
            if not summary and isinstance(ended_info, dict) and ended_info.get("reason"):
                summary = str(ended_info["reason"]).strip() or None

            attention = detail_ticket.get("attention")
            attention_question = (
                str(attention.get("question") or "").strip() or None
                if isinstance(attention, dict)
                else None
            )
            turn_count, step_count, session_cwd, todos, activities = self._parse_worker_session(
                tid, is_active=is_active
            )
            workspace_path = str(detail_ticket.get("directory") or session_cwd or "").strip() or None
            deliverables = self._collect_ticket_attachments(
                ticket_id=tid,
                ticket=detail_ticket,
                text=summary,
                extra_cwd=session_cwd,
                source_key=f"work-detail:{tid}",
            )

            status_labels = {
                "queued": "排队等待执行",
                "running": "正在等待你的确认" if attention_question else "正在执行",
                "waiting_for_input": "等待你的确认",
                "finalizing": "正在整理交付结果",
                "completed": "已完成",
                "dropped": "核查后静默跳过",
                "cancelled": "已停止",
                "failed": "执行未完成",
            }
            return {
                "id": f"superagent:{tid}",
                "ticket_id": tid,
                "title": str(detail_ticket.get("title") or (run_row["title"] if run_row else tid))[:120],
                "status": status,
                "status_label": status_labels.get(status, status),
                "origin_kind": origin_kind,
                "origin_label": origin_label,
                "created_at": created_at,
                "updated_at": updated_at,
                "ended_at": ended_at,
                "source_id": source_id,
                "source_title": source_title,
                "source_recorded_at": source_recorded_at,
                "trigger_preview": trigger_preview,
                "scope": scope,
                "matched_rules": matched_rules,
                "summary": summary,
                "attention_question": attention_question,
                "workspace_path": workspace_path,
                "cancellable": cancellable,
                "turn_count": turn_count,
                "step_count": step_count,
                "todos": todos,
                "activities": activities,
                "attachments": deliverables or [],
            }

        # Fallback: chat_run without an allocated Worker ticket yet
        assert run_row is not None
        proj = self._project_chat_run(run_row)
        trig_preview = None
        if run_row["trigger_id"]:
            trow = self.bridge.db.execute(
                "SELECT text FROM triggers WHERE id=? LIMIT 1", (run_row["trigger_id"],)
            ).fetchone()
            if trow:
                trig_preview = self._clean_trigger_excerpt(str(trow["text"]))
        msg_row = self.store.db.execute(
            "SELECT * FROM messages WHERE run_id=? AND role='assistant' ORDER BY seq DESC LIMIT 1",
            (run_row["run_id"],),
        ).fetchone()
        msg_attachments = self.store._format_message(msg_row).get("attachments", []) if msg_row else []
        st = proj["status"]
        return {
            "id": str(run_row["work_id"]),
            "ticket_id": None,
            "title": str(run_row["title"]),
            "status": st,
            "status_label": "排队等待执行" if st == "queued" else ("正在执行" if st == "running" else st),
            "origin_kind": "chat",
            "origin_label": "对话派发",
            "created_at": float(run_row["created_at"]),
            "updated_at": float(run_row["updated_at"]),
            "ended_at": float(run_row["updated_at"]) if st in ("completed", "failed", "cancelled") else None,
            "source_id": None,
            "source_title": None,
            "source_recorded_at": None,
            "trigger_preview": trig_preview,
            "scope": None,
            "matched_rules": [],
            "summary": str(msg_row["content"])[:400] if msg_row else None,
            "attention_question": None,
            "workspace_path": None,
            "cancellable": bool(proj["cancellable"]),
            "turn_count": 0,
            "step_count": 0,
            "todos": [],
            "activities": [],
            "attachments": msg_attachments,
        }

    def run_page(self, after: int = 0, limit: int = 100, *, include_work: bool = True) -> dict:
        rows = self.bridge.db.execute(
            "SELECT * FROM chat_runs WHERE seq > ? ORDER BY seq ASC LIMIT ?",
            (after, limit + 1),
        ).fetchall()
        runs = [self._project_chat_run(r) for r in rows[:limit]]
        return {
            "data": runs,
            "background_work": self.background_work() if include_work else [],
            "message_states": self.store.message_states() if include_work else {},
            "next_cursor": int(rows[min(limit, len(rows)) - 1]["seq"]) if rows else after,
            "has_more": len(rows) > limit,
        }

    def live_state(self) -> dict:
        runs: list[dict] = []
        cursor = 0
        while True:
            page = self.run_page(cursor, include_work=False)
            runs.extend(page["data"])
            if not page["has_more"]:
                break
            cursor = page["next_cursor"]
        return {
            "runs": runs,
            "background_work": self.background_work(),
            "message_states": self.store.message_states(),
        }

    def publish_live_state(self) -> dict:
        state = self.live_state()
        for run in state["runs"]:
            self.store.events.changed("run:" + run["run_id"], "run.updated", {"run": run})
        self.store.events.changed(
            "work",
            "work.updated",
            {"background_work": state["background_work"], "message_states": state["message_states"]},
        )
        return state

    def live_snapshot(self) -> dict:
        state = self.publish_live_state()
        top = self.store.db.execute("SELECT coalesce(max(seq),0) FROM messages").fetchone()[0]
        return {
            "conversation_id": self.store.identity["id"],
            "cursor": self.store.events.cursor,
            "messages": self.store.page(before=top + 1),
            **state,
        }

    async def handle_conversation(self, request: web.Request) -> web.Response | web.StreamResponse:
        if refused := self._check_bearer(request):
            return refused
        try:
            suffix = request.match_info["tail"]
            if request.method == "GET" and suffix == "":
                cfg = read_engine_config(self.data)
                return web.json_response(
                    {
                        "conversation_id": self.store.identity["id"],
                        "session_id": self.store.identity["root"],
                        "assistant_id": self.connection["assistant_id"],
                        "instance_id": self.connection["instance_id"],
                        "engine": "superagent",
                        "proactive_mode": cfg["proactive_mode"],
                        "capabilities": {
                            **CAPABILITIES,
                            "system_push": bool(self.push.provider and self.push.provider.ready),
                            "message_idempotency": {
                                "supported": True,
                                "durable": True,
                                "retention_seconds": self.store.MESSAGE_RETENTION_SECONDS,
                            },
                        },
                        "latest_seq": self.store.db.execute("SELECT coalesce(max(seq),0) FROM messages").fetchone()[0],
                    }
                )
            if request.method == "GET" and suffix in ("/messages", "/events"):
                if set(request.query) - {"after", "before", "limit"} or ("after" in request.query and "before" in request.query):
                    raise ValueError("Invalid cursor")
                limit = int(request.query.get("limit", 100))
                after = int(request.query.get("after", 0))
                before = request.query.get("before")
                before = int(before) if before is not None else None
                if not 1 <= limit <= 100 or after < 0 or (before is not None and before < 1):
                    raise ValueError("Invalid cursor")
                return web.json_response(self.store.page(after, before, limit))
            if request.method == "GET" and suffix == "/runs":
                if set(request.query) - {"after", "limit"}:
                    raise ValueError("Invalid run cursor")
                after = int(request.query.get("after", 0))
                limit = int(request.query.get("limit", 100))
                if after < 0 or not 1 <= limit <= 100:
                    raise ValueError("Invalid run cursor")
                return web.json_response(self.run_page(after, limit))
            if request.method == "GET" and suffix == "/snapshot":
                if request.query:
                    raise ValueError("Invalid snapshot query")
                return web.json_response(self.live_snapshot())
            if request.method == "GET" and suffix == "/subscribe":
                return await self.store.events.subscribe(request, lambda: self._check_bearer(request) is None)
            if request.method == "POST" and suffix == "/messages":
                return await self._handle_post_message(request)
            if request.method == "GET" and suffix == "/works":
                if set(request.query) - {"limit"}:
                    raise ValueError("Invalid works query")
                limit = int(request.query.get("limit", 15))
                if not 1 <= limit <= 50:
                    raise ValueError("Invalid works query")
                if self.dsh_ready:
                    with suppress(Exception):
                        fetched = await asyncio.to_thread(self._fetch_dsh_snapshots)
                        self._apply_dsh_projections(*fetched)
                return web.json_response(
                    {
                        "active": self.background_work(),
                        "recent": self.recent_work(limit=limit),
                        "skipped": self.skipped_work(limit=limit),
                    }
                )
            if request.method == "GET" and suffix.startswith("/work/") and "/" not in suffix[len("/work/") :]:
                if request.query:
                    raise ValueError("Invalid work query")
                ident = unquote(suffix[len("/work/") :])
                if not ident or "/" in ident or ".." in ident:
                    raise ValueError("Invalid work")
                detail = await asyncio.to_thread(self._build_work_detail, ident)
                if detail is None:
                    raise web.HTTPNotFound()
                return web.json_response(detail)
            if request.method == "POST" and suffix.startswith("/work/") and suffix.endswith("/cancel"):
                ident = unquote(suffix[len("/work/") : -len("/cancel")])
                if not ident or "/" in ident or ".." in ident:
                    raise ValueError("Invalid work")
                return await self._handle_cancel_work(ident, await request.json())
            if request.method == "POST" and suffix == "/adopt":
                return web.json_response({"adopted": False})
            if suffix in ("/push", "/push/revoke", "/push/visible"):
                device = request.headers.get("X-MoMo-Device")
                if not device or not self.push.paired(device):
                    raise web.HTTPForbidden()
                if request.method == "GET" and suffix == "/push":
                    return web.json_response(self.push.status(device))
                if request.method == "POST" and suffix == "/push":
                    return web.json_response(self.push.register(device, await request.json()))
                if request.method == "POST" and suffix == "/push/revoke":
                    self.push.revoke(device)
                    return web.json_response(self.push.status(device))
                if request.method == "POST" and suffix == "/push/visible":
                    self.push.visible_controls(device, await request.json())
                    return web.json_response({"ok": True})
                raise web.HTTPNotFound()
            if request.method == "POST" and suffix == "/read":
                value = await request.json()
                seq = value.get("through_seq")
                top = self.store.db.execute("SELECT coalesce(max(seq),0) FROM messages").fetchone()[0]
                if set(value) != {"through_seq"} or type(seq) is not int or not 0 <= seq <= top:
                    raise ValueError("Invalid read position")
                device = request.headers.get("X-MoMo-Device", "local")
                self.push.read(device, seq)
                return web.json_response({"through_seq": seq})
            raise web.HTTPNotFound()
        except (ValueError, KeyError, TypeError) as exc:
            return web.json_response({"error": {"code": "invalid_request", "message": str(exc)}}, status=400)

    async def _handle_post_message(self, request: web.Request) -> web.Response | web.StreamResponse:
        value = await request.json()
        allowed = {"operation_id", "content", "intent", "target_run_id", "execution_generation", "work_id", "attachments"}
        if set(value) - allowed:
            raise ValueError("Invalid message fields")
        target = value.get("target_run_id")
        generation = value.get("execution_generation")
        intent = value.get("intent", "steer" if target else "new")
        if intent not in ("new", "steer") or (intent == "steer") != bool(target):
            raise ValueError("Invalid intent")
        if intent == "new" and any(k in value for k in ("execution_generation", "work_id")):
            raise ValueError("Invalid new message")
        operation = str(uuid.UUID(value["operation_id"]))
        content = value.get("content", "")
        attachments = self._validate_attachments(value.get("attachments"))
        if attachments and intent == "steer":
            raise ValueError("Attachments require a new message")
        if not isinstance(content, str) or len(content.encode()) > 16384 or (not content.strip() and not attachments):
            raise ValueError("Invalid message")

        work_id = value.get("work_id")
        if target:
            target_row = self.bridge.db.execute("SELECT * FROM chat_runs WHERE run_id=?", (target,)).fetchone()
            if not target_row or target_row["status"] not in ("queued", "started", "waiting_for_input"):
                _conflict("stale_target")
            work_id = target_row["work_id"]

        scope = hashlib.sha256(("superagent\0" + self.api_key).encode()).hexdigest()
        row = self.store.accept(
            operation,
            content,
            scope,
            target,
            generation,
            work_id,
            active_context=[],
            attachments=attachments,
        )
        run_id = row["run_id"]
        existing_run = self.bridge.db.execute("SELECT * FROM chat_runs WHERE run_id=?", (run_id,)).fetchone()
        if existing_run is None:
            prompt_text = content if content.strip() else "请查看我发送的附件。"
            for item in attachments or ():
                if item.get("kind") == "document" and item.get("text"):
                    prompt_text += f"\n\n[附件文件: {item['name']}]\n{item['text']}"
                elif item.get("kind") == "image" and item.get("data"):
                    attach_dir = self.data / "workspace/attachments"
                    attach_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
                    safe_name = "".join(c if c.isalnum() or c in ("-", "_", ".") else "_" for c in Path(item["name"]).name) or "image.jpg"
                    saved_path = attach_dir / f"{item['id'][:8]}_{safe_name}"
                    if not saved_path.exists():
                        saved_path.write_bytes(base64.b64decode(item["data"]))
                    prompt_text += f"\n\n[用户附带图片: {item['name']} (本地路径: {saved_path})]"

            msg_id = f"user-{operation}"
            trigger_id = f"momo:{msg_id}"
            thread_id = f"chat:{row['work_id']}"
            now = time.time()
            title = " ".join(content.split())[:64] or "对话消息"
            with self.bridge.db:
                self.bridge.db.execute(
                    """INSERT INTO chat_runs(
                           run_id, operation_id, session_id, work_id, title, status, trigger_id,
                           intent, delivery_state, execution_generation, created_at, updated_at
                       ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        run_id,
                        operation,
                        self.store.identity["root"],
                        row["work_id"],
                        title,
                        "queued",
                        trigger_id,
                        intent,
                        "applied" if intent == "steer" else None,
                        1,
                        now,
                        now,
                    ),
                )
            if intent == "steer":
                with self.store.db:
                    self.store.db.execute(
                        "UPDATE inputs SET state='admitted', delivery_state='applied' WHERE operation_id=?",
                        (operation,),
                    )
            else:
                with self.store.db:
                    self.store.db.execute("UPDATE inputs SET state='admitted' WHERE operation_id=?", (operation,))
            self.bridge.enqueue_trigger(
                trigger_id=trigger_id,
                kind="chat",
                thread_id=thread_id,
                message_id=f"user-{operation}",
                actor_id="owner",
                actor_name="User",
                addressed=True,
                human=True,
                observed=False,
                text=prompt_text,
                run_id=run_id,
            )
            self._trigger_wakeup.set()

        saved_run = self.bridge.db.execute("SELECT * FROM chat_runs WHERE run_id=?", (run_id,)).fetchone()
        projected = self._project_chat_run(saved_run)
        receipt = {
            **projected,
            "message_id": "user-" + operation,
            "intent": intent,
            "disposition": "steering" if target else "queued",
        }
        self.store.events.changed("run:" + run_id, "run.updated", {"run": receipt})
        if request.headers.get("Accept") == "text/event-stream":
            return await self._stream_run_sse(request, receipt)
        return web.json_response(receipt)

    async def _stream_run_sse(self, request: web.Request, receipt: dict) -> web.StreamResponse:
        run_id = receipt["run_id"]
        resp = web.StreamResponse(
            status=200,
            headers={
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )
        await resp.prepare(request)

        async def _send(event_name: str, data: dict) -> None:
            payload = f"event: {event_name}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
            await resp.write(payload.encode("utf-8"))

        await _send("run.accepted", {"event": "run.accepted", "run_id": run_id, "receipt": receipt})
        current = self.bridge.db.execute("SELECT * FROM chat_runs WHERE run_id=?", (run_id,)).fetchone()
        if current and current["status"] in ("completed", "failed", "cancelled"):
            for msg in self.store.db.execute(
                "SELECT * FROM messages WHERE run_id=? AND role='assistant' ORDER BY seq ASC", (run_id,)
            ):
                await _send(
                    "message.committed",
                    {"event": "message.committed", "run_id": run_id, "message": self.store._format_message(msg)},
                )
            await _send(f"run.{current['status']}", {"event": f"run.{current['status']}", "run_id": run_id})
            return resp

        queue: asyncio.Queue = asyncio.Queue()
        self._run_streams.setdefault(run_id, []).append(queue)
        try:
            while True:
                item = await asyncio.wait_for(queue.get(), timeout=180.0)
                if item is None:
                    break
                await _send(item["event"], item)
        except (asyncio.TimeoutError, ConnectionResetError, asyncio.CancelledError):
            pass
        finally:
            queues = self._run_streams.get(run_id, [])
            if queue in queues:
                queues.remove(queue)
        return resp

    def _emit_run_stream(self, run_id: str, event: dict) -> None:
        self.store.events.publish("run.event", {"run_event": event})
        for queue in list(self._run_streams.get(run_id, ())):
            queue.put_nowait(event)

    def _finish_run_stream(self, run_id: str, status: str) -> None:
        self._emit_run_stream(run_id, {"event": f"run.{status}", "run_id": run_id})
        for queue in list(self._run_streams.pop(run_id, ())):
            queue.put_nowait(None)

    async def _handle_cancel_work(self, ident: str, body: dict) -> web.Response:
        if set(body) - {"operation_id", "execution_generation", "target_run_id"} or type(body.get("execution_generation")) is not int:
            raise ValueError("Invalid cancellation")
        str(uuid.UUID(body["operation_id"]))
        ticket_id = None
        if ident.startswith("superagent:"):
            ticket_id = ident.removeprefix("superagent:")
        elif ident.startswith("proactive-"):
            ticket_id = ident.removeprefix("proactive-")
        run_row = self.bridge.db.execute(
            "SELECT * FROM chat_runs WHERE work_id=? OR run_id=? OR (ticket_id IS NOT NULL AND ticket_id=?) ORDER BY seq DESC LIMIT 1",
            (ident, body.get("target_run_id") or "", ticket_id or ""),
        ).fetchone()
        if run_row and run_row["ticket_id"]:
            ticket_id = run_row["ticket_id"]
        if ticket_id and self.dsh_ready:
            with suppress(Exception):
                await asyncio.to_thread(
                    dsh_api_request,
                    self.dsh_port,
                    "POST",
                    f"/orchestrator/api/tickets/{ticket_id}/stop",
                    {},
                )
                fetched = await asyncio.to_thread(self._fetch_dsh_snapshots)
                self._apply_dsh_projections(*fetched)
        elif ticket_id:
            self._cached_tickets = [
                {**t, "state": "ended", "ended": {"outcome": "stopped"}} if t.get("id") == ticket_id else t
                for t in self._cached_tickets
            ]
        if run_row:
            with self.bridge.db:
                self.bridge.db.execute(
                    "UPDATE chat_runs SET status='cancelled', cancellable=0, cancel_requested=1, updated_at=? WHERE run_id=?",
                    (time.time(), run_row["run_id"]),
                )
            self._finish_run_stream(run_row["run_id"], "cancelled")
        self.publish_live_state()
        return web.json_response({"id": ident, "cancel_requested": True, "state": "cancelled"}, status=200)

    # ── Internal Loopback Bridge Endpoints for dsh-superagent-momo ──────────────

    async def handle_internal_triggers(self, request: web.Request) -> web.Response:
        if refused := self._check_bridge_secret(request):
            return refused
        try:
            after = max(0, int(request.query.get("after", "0") or 0))
        except ValueError:
            after = 0
        try:
            wait_ms = max(0, min(15_000, int(request.query.get("wait_ms", "0") or 0)))
        except ValueError:
            wait_ms = 0
        items, cursor, polled_runs = self.bridge.list_triggers(after)
        if not items and wait_ms > 0:
            self._trigger_wakeup.clear()
            items, cursor, polled_runs = self.bridge.list_triggers(after)
            if not items:
                with suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(self._trigger_wakeup.wait(), timeout=wait_ms / 1000.0)
                items, cursor, polled_runs = self.bridge.list_triggers(after)

        if polled_runs:
            now = time.time()
            with self.bridge.db:
                for run_id in polled_runs:
                    self.bridge.db.execute(
                        "UPDATE chat_runs SET status='started', updated_at=? WHERE run_id=? AND status='queued'",
                        (now, run_id),
                    )
            self.publish_live_state()
        return web.json_response({"events": items, "next_cursor": cursor})

    async def _computer_ticket(self, ticket_id: str) -> dict:
        from urllib.parse import quote
        return await asyncio.to_thread(dsh_api_request, self.dsh_port, "GET", "/orchestrator/api/tickets/" + quote(ticket_id, safe=""))

    async def handle_internal_computer(self, request: web.Request) -> web.Response:
        if refused := self._check_bridge_secret(request):
            return refused
        try:
            payload = await request.read()
            if len(payload) > 16384: raise ValueError("Computer request is too large")
            body = json.loads(payload)
            if not isinstance(body, dict) or not isinstance(body.get("args"), dict): raise ValueError("Invalid computer request")
            result = await self.computer.call(body.get("ticket_id"), body.get("assignment_id"), body.get("op"), body["args"])
            return web.json_response(result)
        except PermissionError as error:
            return web.json_response({"error": str(error)}, status=409)
        except (ValueError, RuntimeError, OSError, TimeoutError) as error:
            return web.json_response({"error": str(error)}, status=400)

    async def handle_internal_context(self, request: web.Request) -> web.Response:
        if refused := self._check_bridge_secret(request):
            return refused
        thread_id = request.query.get("thread_id", "")
        source_id = request.query.get("source_id", "")
        message_id = request.query.get("message_id", "")
        cursor = request.query.get("cursor", "")
        try:
            limit = max(5, min(50, int(request.query.get("limit", "20") or 20)))
        except ValueError:
            limit = 20
        if thread_id.startswith("transcript:") or source_id:
            raw_tid = thread_id.partition(":")[2]
            sid = source_id or re.split(r":[ws]\d+", raw_tid, maxsplit=1)[0]
            messages, next_cursor = self._transcript_thread_messages(
                sid, message_id=message_id, cursor=cursor, limit=limit
            )
            recent_tickets = self._recent_proactive_ticket_summaries(source_id=sid, max_items=8)
            payload: dict = {
                "messages": messages,
                "body": {
                    "source_id": sid,
                    **({"recent_tickets": recent_tickets} if recent_tickets else {}),
                },
            }
            if next_cursor:
                payload["next"] = next_cursor
            return web.json_response(payload)
        rows = self.store.db.execute(
            "SELECT id, role, content, created_at FROM messages ORDER BY seq DESC LIMIT 30"
        ).fetchall()
        messages = [
            {
                "id": row["id"],
                "from": "assistant" if row["role"] == "assistant" else "owner",
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(row["created_at"])),
                "text": row["content"],
                **({"bot": True} if row["role"] == "assistant" else {}),
            }
            for row in reversed(rows)
        ]
        return web.json_response({"messages": messages, "body": {"thread_id": thread_id}})

    def _transcript_thread_messages(
        self,
        source_id: str,
        *,
        message_id: str = "",
        cursor: str = "",
        limit: int = 20,
    ) -> tuple[list[dict], str | None]:
        context_dir = self.data / "context"
        if not (context_dir / "context.sqlite").is_file():
            return [], None
        from context_store import ContextStore

        cstore = ContextStore(context_dir)
        try:
            src = cstore.db.execute(
                "SELECT id, payload, updated FROM sources WHERE id=? AND deleted = 0",
                (source_id,),
            ).fetchone()
            if not src:
                return [], None
            payload = json.loads(src["payload"])
            spans = payload.get("spans") or []
            if not spans:
                return [], None

            # Group spans into ~1000-char chronological passages across the entire recording (never truncating at 120 spans).
            source_is_attributed = any(
                classify_transcript_span(s)[1] is not None for s in spans if isinstance(s, dict)
            )
            passages: list[dict] = []
            buf_lines: list[str] = []
            buf_chars = 0
            buf_has_owner = False
            buf_other_label = ""
            buf_at = float(src["updated"])

            def _passage_sender(has_owner: bool, other_label: str) -> str:
                if has_owner:
                    return "owner"
                if other_label:
                    return f"other:{other_label}"
                return "unattributed" if source_is_attributed else "owner"

            for span in spans:
                spk_label, spk_is_owner, spk_body = classify_transcript_span(span)
                if not spk_body:
                    continue
                ts = float(span.get("recorded_at") or src["updated"])
                dt_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
                line = format_transcript_span_line(dt_str, span)
                if not line:
                    continue
                if buf_lines and buf_chars + len(line) + 1 > 1000:
                    passages.append(
                        {
                            "id": f"rec-{source_id}-p{len(passages)}",
                            "from": _passage_sender(buf_has_owner, buf_other_label),
                            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(buf_at)),
                            "text": "\n".join(buf_lines),
                        }
                    )
                    buf_lines = []
                    buf_chars = 0
                    buf_has_owner = False
                    buf_other_label = ""
                if not buf_lines:
                    buf_at = ts
                if spk_is_owner is True:
                    buf_has_owner = True
                elif spk_is_owner is False and not buf_other_label:
                    buf_other_label = spk_label or "other"
                buf_lines.append(line)
                buf_chars += len(line) + 1
            if buf_lines:
                passages.append(
                    {
                        "id": f"rec-{source_id}-p{len(passages)}",
                        "from": _passage_sender(buf_has_owner, buf_other_label),
                        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(buf_at)),
                        "text": "\n".join(buf_lines),
                    }
                )
            if not passages:
                return [], None

            target_idx = len(passages) - 1
            if message_id:
                trig_row = self.bridge.db.execute(
                    "SELECT text, at_iso FROM triggers WHERE message_id=? OR id=? ORDER BY seq DESC LIMIT 1",
                    (message_id, f"momo:{message_id}"),
                ).fetchone()
                if trig_row and trig_row["text"]:
                    trig_lines = [
                        ln.strip()
                        for ln in str(trig_row["text"]).splitlines()
                        if ln.strip()
                        and (
                            not ln.strip().startswith("[")
                            or bool(re.match(r"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]", ln.strip()))
                            or bool(re.match(r"^\[\d{2}:\d{2}:\d{2}\]", ln.strip()))
                        )
                    ]
                    probe = trig_lines[-1] if trig_lines else ""
                    if probe:
                        for p_idx in range(len(passages) - 1, -1, -1):
                            if probe in passages[p_idx]["text"]:
                                target_idx = p_idx
                                break
                    passages[target_idx]["id"] = message_id
                    if str(trig_row["text"]) not in passages[target_idx]["text"]:
                        passages[target_idx]["text"] = passages[target_idx]["text"] + "\n" + str(trig_row["text"])
                else:
                    passages[target_idx]["id"] = message_id

            if len(passages) <= limit:
                return passages, None

            if cursor.startswith("offset:"):
                try:
                    offset = max(0, int(cursor.partition(":")[2]))
                except ValueError:
                    offset = 0
                page = passages[offset : offset + limit]
                nxt = f"offset:{offset + limit}" if offset + limit < len(passages) else None
                return page, nxt

            if target_idx < limit:
                return passages[:limit], f"offset:{limit}"

            win_len = max(3, limit - 2)
            start = max(2, min(len(passages) - win_len, target_idx - (win_len // 2)))
            initial = [passages[0], passages[1], *passages[start : start + win_len]]
            nxt = f"offset:{start + win_len}" if start + win_len < len(passages) else None
            return initial, nxt
        finally:
            cstore.close()

    def _collect_ticket_attachments(
        self,
        *,
        ticket_id: str | None,
        ticket: dict | None = None,
        text: str | None = None,
        extra_cwd: str | None = None,
        source_key: str = "",
    ) -> list[dict] | None:
        workspace_root = self.data / "workspace"
        work_root = self.dsh_work_dir
        allowed_roots = [workspace_root, work_root]
        extra_dirs: list[Path] = []
        t_obj = ticket
        if t_obj is None and ticket_id:
            t_obj = next(
                (t for t in self._cached_tickets if isinstance(t, dict) and str(t.get("id")) == ticket_id),
                None,
            )
            if t_obj is None and self.dsh_ready:
                with suppress(Exception):
                    fetched = dsh_api_request(
                        self.dsh_port,
                        "GET",
                        f"/orchestrator/api/tickets/{quote(ticket_id, safe='')}",
                        timeout=2.5,
                    )
                    if isinstance(fetched, dict) and fetched.get("id"):
                        t_obj = fetched
        if isinstance(t_obj, dict):
            t_name = str(t_obj.get("name") or "").strip()
            t_dir = str(t_obj.get("directory") or "").strip()
            if t_name and "/" not in t_name and ".." not in t_name:
                extra_dirs.append(workspace_root / t_name)
                extra_dirs.append(work_root / t_name)
            if t_dir:
                extra_dirs.append(Path(t_dir))
        if extra_cwd:
            extra_dirs.append(Path(extra_cwd))
        if ticket_id and "/" not in ticket_id and ".." not in ticket_id:
            suffix = ticket_id[:12]
            for root in (workspace_root, work_root):
                if root.is_dir():
                    with suppress(OSError):
                        for child in root.iterdir():
                            if child.is_dir() and (child.name == ticket_id or child.name.endswith(f"-{suffix}")):
                                extra_dirs.append(child)
        combined_text = text or ""
        if isinstance(t_obj, dict) and t_obj.get("summary"):
            combined_text = f"{combined_text}\n{t_obj['summary']}".strip()
        return collect_deliverable_attachments(
            combined_text,
            allowed_roots=allowed_roots,
            extra_dirs=extra_dirs,
            source_key=source_key,
        )

    async def handle_internal_outbound(self, request: web.Request) -> web.Response:
        if refused := self._check_bridge_secret(request):
            return refused
        body = await request.json()
        out_id = str(body.get("id") or "").strip()
        kind = str(body.get("kind") or "reply").strip()
        text = str(body.get("text") or "").strip()
        ticket_id = str(body.get("ticket_id") or "").strip() or None
        channel = body.get("channel") if isinstance(body.get("channel"), dict) else {}
        channel_id = str(channel.get("id") or channel.get("thread") or "chat:main")
        address = channel.get("address") if isinstance(channel.get("address"), dict) else {}
        address_msg_id = str(address.get("messageId") or "").strip()
        if not out_id or not text:
            return web.json_response({"error": "invalid_outbound"}, status=400)

        existing = self.bridge.db.execute("SELECT * FROM outbound_receipts WHERE id=?", (out_id,)).fetchone()
        if existing:
            return web.json_response({"status": "sent", "duplicate": True, "message_id": existing["message_id"]})

        now = time.time()
        # Locate linked chat run by ticket_id, exact trigger messageId, or oldest active chat run on chat:* channel.
        linked_run = None
        if ticket_id:
            linked_run = self.bridge.db.execute(
                "SELECT * FROM chat_runs WHERE ticket_id=? ORDER BY seq DESC LIMIT 1", (ticket_id,)
            ).fetchone()
        if linked_run is None and address_msg_id:
            trig_lookup = address_msg_id if address_msg_id.startswith("momo:") else f"momo:{address_msg_id}"
            linked_run = self.bridge.db.execute(
                "SELECT * FROM chat_runs WHERE trigger_id=? ORDER BY seq DESC LIMIT 1", (trig_lookup,)
            ).fetchone()
        if linked_run is None and channel_id.startswith("chat:"):
            linked_run = self.bridge.db.execute(
                "SELECT * FROM chat_runs WHERE status IN ('queued', 'started', 'waiting_for_input') ORDER BY seq ASC LIMIT 1"
            ).fetchone()

        if kind == "acknowledgement":
            if linked_run:
                with self.bridge.db:
                    self.bridge.db.execute(
                        "UPDATE chat_runs SET status='started', ticket_id=coalesce(?, ticket_id), updated_at=? WHERE run_id=?",
                        (ticket_id, now, linked_run["run_id"]),
                    )
                    self.bridge.db.execute(
                        "INSERT INTO outbound_receipts VALUES(?,?,?,?,?,?)",
                        (out_id, kind, channel_id, ticket_id, None, now),
                    )
                self.publish_live_state()
            else:
                with self.bridge.db:
                    self.bridge.db.execute(
                        "INSERT INTO outbound_receipts VALUES(?,?,?,?,?,?)",
                        (out_id, kind, channel_id, ticket_id, None, now),
                    )
            return web.json_response({"status": "sent"})

        # kind == "reply": commit visible assistant message to shared ProductStore!
        if linked_run:
            run_id = linked_run["run_id"]
        else:
            # Proactive deliverable from voice transcript or life signal!
            run_id = f"run_proactive_{ticket_id or hashlib.sha256(out_id.encode()).hexdigest()[:16]}"
            work_id = f"work_proactive_{ticket_id or hashlib.sha256(out_id.encode()).hexdigest()[:12]}"
            proactive_title = "主动跟进"
            for t in self._cached_tickets:
                if t.get("id") == ticket_id and t.get("title"):
                    proactive_title = str(t["title"])[:64]
                    break
            with self.bridge.db:
                self.bridge.db.execute(
                    """INSERT OR IGNORE INTO chat_runs(
                           run_id, operation_id, session_id, work_id, title, status,
                           ticket_id, intent, cancellable, created_at, updated_at
                       ) VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        run_id,
                        None,
                        self.store.identity["root"],
                        work_id,
                        proactive_title,
                        "completed",
                        ticket_id,
                        "new",
                        0,
                        now,
                        now,
                    ),
                )

        deliverables = self._collect_ticket_attachments(
            ticket_id=ticket_id,
            text=text,
            source_key=f"superagent:{out_id}",
        )
        msg_id = self.store.append_assistant(
            f"superagent:{out_id}",
            text,
            now,
            run_id=run_id,
            attachments=deliverables,
        )
        msg_row = self.store.db.execute("SELECT * FROM messages WHERE id=?", (msg_id,)).fetchone()
        with self.bridge.db:
            self.bridge.db.execute(
                "INSERT INTO outbound_receipts VALUES(?,?,?,?,?,?)",
                (out_id, kind, channel_id, ticket_id, msg_id, now),
            )
            self.bridge.db.execute(
                """UPDATE chat_runs
                   SET status='completed', ticket_id=coalesce(?, ticket_id), wait_reason=NULL, cancellable=0, updated_at=?
                   WHERE run_id=?""",
                (ticket_id, now, run_id),
            )
        if msg_row:
            formatted = self.store._format_message(msg_row)
            self._emit_run_stream(run_id, {"event": "message.committed", "run_id": run_id, "message": formatted})
            self.push.emit(f"terminal:superagent:{out_id}", "final", run_id=run_id, message=formatted, historical=False)
        self._finish_run_stream(run_id, "completed")
        self.publish_live_state()
        return web.json_response({"status": "sent", "message_id": msg_id})


def run_superagent_gateway(data: Path, connection: dict, *, python_executable: Path, base_env: dict[str, str]) -> None:
    """Start ContextService + SuperAgentGateway on the configured MoMo loopback ports."""
    from context_server import ContextService

    resolve_superagent_llm(data)
    prepared_dsh_binary(data)

    context = ContextService(data, connection)
    gateway = SuperAgentGateway(
        data,
        connection,
        python_executable=python_executable,
        base_env=base_env,
        manage_dsh=True,
    )
    app = gateway.create_app()
    print(
        json.dumps(
            {
                "application": "MoMoAgent",
                "engine": "superagent",
                "runtime_source": str(REPOSITORY / "Vendor/SuperAgent"),
                "data_directory": str(data),
                "upstream_commit": superagent_fingerprint()["upstream_commit"],
            }
        ),
        flush=True,
    )
    context.start()
    try:
        web.run_app(app, host="127.0.0.1", port=connection["port"], print=None, access_log=None)
    finally:
        context.close()
