"""Unit & integration tests for pluggable runtime engine (Hermes <-> DeepSeek SuperAgent) and proactive bridge."""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

from aiohttp.test_utils import TestClient, TestServer

REPOSITORY = Path(__file__).resolve().parents[2]
for extra in (
    REPOSITORY / "Apps/MacApp/Runtime",
    REPOSITORY / "Apps/MacApp/Context",
    REPOSITORY / "Apps/MacApp/Access",
    REPOSITORY / "Vendor/HermesAgent",
):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

import momo_agent
from context_store import ContextStore, digest


def make_source_payload(title: str, texts: list[str], *, session_id: str | None = None) -> dict:
    lib = "11111111-1111-4111-8111-111111111111"
    dev = "22222222-2222-4222-8222-222222222222"
    sess = session_id or str(uuid.uuid4())
    spans = [
        {"id": str(uuid.uuid4()), "text": txt, "recorded_at": 1761897600.0 + idx * 10.0}
        for idx, txt in enumerate(texts)
    ]
    joined = "\n".join(s["text"] for s in spans)
    return {
        "library_id": lib,
        "session_id": sess,
        "device_id": dev,
        "generation": 1,
        "version": 1,
        "deleted": False,
        "title": title,
        "text_sha256": digest(joined),
        "spans": spans,
    }
from conversation_store import ProductStore
from hermes_memory import HermesMemory
from rtc_transport import permitted_route
from runtime_engine import engine_config_path, read_engine_config, write_engine_config
from superagent_gateway import SuperAgentGateway


class RuntimeEngineConfigTests(unittest.TestCase):
    def test_defaults_to_superagent_without_creating_files_and_persists_privately(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "Agent"
            momo_agent.initialize(data, 19810)
            self.assertFalse(engine_config_path(data).exists())
            self.assertEqual(read_engine_config(data), {"engine": "superagent", "proactive_mode": "auto"})

            updated = write_engine_config(data, engine="hermes", proactive_mode="observe")
            self.assertEqual(updated, {"engine": "hermes", "proactive_mode": "observe"})
            self.assertEqual(engine_config_path(data).stat().st_mode & 0o777, 0o600)
            self.assertEqual(read_engine_config(data), {"engine": "hermes", "proactive_mode": "observe"})

            reverted = write_engine_config(data, engine="superagent")
            self.assertEqual(reverted, {"engine": "superagent", "proactive_mode": "observe"})

            with self.assertRaises(ValueError):
                write_engine_config(data, engine="invalid")
            with self.assertRaises(ValueError):
                write_engine_config(data, proactive_mode="invalid")

    def test_webrtc_route_allowlist_permits_proactive_endpoints(self) -> None:
        self.assertEqual(permitted_route("GET", "/momo/v1/proactive"), ("/momo/v1/proactive", False, False))
        self.assertEqual(permitted_route("POST", "/momo/v1/proactive"), ("/momo/v1/proactive", False, False))
        self.assertEqual(permitted_route("POST", "/momo/v1/proactive/ingest"), ("/momo/v1/proactive/ingest", False, False))
        self.assertEqual(permitted_route("GET", "/momo/v1/conversation/works"), ("/momo/v1/conversation/works", False, False))
        self.assertEqual(permitted_route("GET", "/momo/v1/conversation/works?limit=15"), ("/momo/v1/conversation/works?limit=15", False, False))
        self.assertEqual(
            permitted_route("GET", "/momo/v1/conversation/work/superagent%3At-101"),
            ("/momo/v1/conversation/work/superagent%3At-101", False, False),
        )
        self.assertEqual(
            permitted_route("GET", "/momo/v1/conversation/work/superagent:t-101"),
            ("/momo/v1/conversation/work/superagent:t-101", False, False),
        )
        self.assertIsNone(permitted_route("GET", "/momo/v1/conversation/work/..%2Fsecret"))
        self.assertIsNone(permitted_route("GET", "/momo/v1/proactive/ingest"))
        self.assertIsNone(permitted_route("GET", "/momo/internal/superagent/triggers"))


class SharedContextAndMemoryCLITests(unittest.TestCase):
    def test_momo_cli_shares_recordings_and_hermes_memories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "Agent"
            momo_agent.initialize(data, 19820)
            cstore = ContextStore(data / "context")
            try:
                synced = cstore.sync_source(
                    make_source_payload("架构讨论", ["下周一把 SuperAgent 主动特性合并进主线。"])
                )
            finally:
                cstore.close()

            cli = str(REPOSITORY / "Apps/MacApp/Runtime/momo_cli.py")
            search_out = json.loads(
                subprocess.check_output([sys.executable, cli, "--data-dir", str(data), "search", "SuperAgent"], text=True)
            )
            self.assertEqual(len(search_out["matches"]), 1)
            self.assertEqual(search_out["matches"][0]["source_id"], synced["source_id"])

            add_out = json.loads(
                subprocess.check_output(
                    [sys.executable, cli, "--data-dir", str(data), "remember", "--target", "user", "用户偏好三段式精简纪要"],
                    text=True,
                )
            )
            self.assertTrue(add_out.get("success"))

            # Verify HermesMemory sees the exact entry written by SuperAgent's momo-cli!
            hermes_items = HermesMemory(data / "hermes").list()["items"]
            self.assertEqual(len(hermes_items), 1)
            self.assertIn("三段式精简纪要", hermes_items[0]["text"])


class SuperAgentGatewayBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_gateway_preserves_shared_conversation_and_runs_explicit_plus_proactive_flows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "Agent"
            conn = momo_agent.initialize(data, 19830)
            cfg = json.loads((data / "hermes/config.yaml").read_text(encoding="utf-8"))
            cfg["model"] = {"provider": "custom", "default": "deepseek-chat", "base_url": "https://api.deepseek.com/v1"}
            momo_agent.atomic_private(data / "hermes/config.yaml", json.dumps(cfg) + "\n")

            # Seed an existing message while engine is Hermes, then switch to SuperAgent.
            hermes_store = ProductStore(data / "runtime/conversation.sqlite", conn)
            hermes_msg_id = hermes_store.append_assistant("hermes:seed:1", "这是 Hermes 阶段的历史消息。", 1700000000.0)
            conv_id = hermes_store.identity["id"]
            hermes_store.db.close()

            write_engine_config(data, engine="superagent", proactive_mode="auto")
            gateway = SuperAgentGateway(
                data,
                conn,
                python_executable=Path(sys.executable),
                base_env=momo_agent.child_environment(data),
                manage_dsh=False,
            )
            server = TestServer(gateway.create_app())
            client = TestClient(server)
            await client.start_server()
            try:
                auth = {"Authorization": f"Bearer {gateway.api_key}"}
                bridge_headers = {"X-MoMo-Bridge": gateway.bridge_secret}

                # 1. Auth checks
                unauth = await client.get("/v1/capabilities")
                self.assertEqual(unauth.status, 401)
                bad_bridge = await client.get("/momo/internal/superagent/triggers")
                self.assertEqual(bad_bridge.status, 403)

                caps = await (await client.get("/v1/capabilities", headers=auth)).json()
                self.assertEqual(caps["engine"], "superagent")
                self.assertTrue(caps["features"]["runs_idempotency"]["durable"])

                # 2. Shared conversation identity & history across engine switch
                meta = await (await client.get("/momo/v1/conversation", headers=auth)).json()
                self.assertEqual(meta["conversation_id"], conv_id)
                msgs = await (await client.get("/momo/v1/conversation/messages", headers=auth)).json()
                self.assertEqual(msgs["data"][0]["id"], hermes_msg_id)

                # 3. Explicit user chat -> trigger long-poll -> queued -> started -> ack -> reply -> completed
                op_id = str(uuid.uuid4())
                post_resp = await client.post(
                    "/momo/v1/conversation/messages",
                    headers=auth,
                    json={"operation_id": op_id, "content": "帮我查一下今天的安排"},
                )
                self.assertEqual(post_resp.status, 200)
                receipt = await post_resp.json()
                run_id = receipt["run_id"]
                self.assertEqual(receipt["status"], "queued")

                polled = await (await client.get("/momo/internal/superagent/triggers?after=0", headers=bridge_headers)).json()
                self.assertEqual(len(polled["events"]), 1)
                self.assertIsInstance(polled["next_cursor"], str)
                trig = polled["events"][0]
                self.assertEqual(trig["stream"], "chat")
                self.assertEqual(trig["addressed"], "direct")
                self.assertEqual(trig["id"], f"user-{op_id}")

                chat_ctx = await (
                    await client.get(
                        f"/momo/internal/superagent/context?thread_id={trig['thread_id']}&message_id={trig['id']}",
                        headers=bridge_headers,
                    )
                ).json()
                # Assistant message has bot=True; user message omits 'bot' per strict ContextMessageSchema!
                self.assertTrue(chat_ctx["messages"][0]["bot"])
                self.assertNotIn("bot", chat_ctx["messages"][1])
                self.assertEqual(chat_ctx["messages"][1]["id"], trig["id"])

                runs_mid = await (await client.get("/momo/v1/conversation/runs", headers=auth)).json()
                self.assertEqual(runs_mid["data"][0]["status"], "running")
                legacy_run = await (await client.get(f"/v1/runs/{run_id}", headers=auth)).json()
                self.assertEqual(legacy_run["status"], "started")

                ack_resp = await client.post(
                    "/momo/internal/superagent/outbound",
                    headers=bridge_headers,
                    json={
                        "id": "ack-1",
                        "kind": "acknowledgement",
                        "channel": {
                            "source": "momo",
                            "thread": trig["thread_id"],
                            "address": {"stream": "chat", "threadId": trig["thread_id"], "messageId": trig["id"]},
                        },
                        "ticket_id": "t-101",
                        "text": "正在查询今日日程。",
                    },
                )
                self.assertEqual(ack_resp.status, 200)

                reply_payload = {
                    "id": "reply-1",
                    "kind": "reply",
                    "channel": {
                        "source": "momo",
                        "thread": trig["thread_id"],
                        "address": {"stream": "chat", "threadId": trig["thread_id"], "messageId": trig["id"]},
                    },
                    "ticket_id": "t-101",
                    "text": "你今天下午 3 点有一场产品评审。",
                }
                reply_resp = await client.post("/momo/internal/superagent/outbound", headers=bridge_headers, json=reply_payload)
                self.assertEqual(reply_resp.status, 200)
                # Duplicate retry is idempotent (no duplicate chat bubble!)
                dup_resp = await (await client.post("/momo/internal/superagent/outbound", headers=bridge_headers, json=reply_payload)).json()
                self.assertTrue(dup_resp["duplicate"])

                runs_done = await (await client.get("/momo/v1/conversation/runs", headers=auth)).json()
                self.assertEqual(runs_done["data"][0]["status"], "completed")

                # 4. Proactive unaddressed voice transcript -> context window -> proactive deliverable!
                cstore = ContextStore(data / "context")
                try:
                    synced_proactive = cstore.sync_source(
                        make_source_payload("晚间备忘", ["备忘一下：明早九点前把发布检查表整理出来。"])
                    )
                finally:
                    cstore.close()

                ingested = await (await client.post("/momo/v1/proactive/ingest", headers=auth, json={})).json()
                self.assertEqual(ingested["count"], 1)

                polled2 = await (
                    await client.get(f"/momo/internal/superagent/triggers?after={polled['next_cursor']}", headers=bridge_headers)
                ).json()
                self.assertEqual(len(polled2["events"]), 1)
                pt = polled2["events"][0]
                self.assertEqual(pt["stream"], "transcripts")
                self.assertNotIn("addressed", pt)
                self.assertEqual(pt["title"], "晚间备忘")
                self.assertEqual(pt["source_id"], synced_proactive["source_id"])

                ctx_win = await (
                    await client.get(
                        f"/momo/internal/superagent/context?thread_id={pt['thread_id']}&message_id={pt['id']}&source_id={synced_proactive['source_id']}",
                        headers=bridge_headers,
                    )
                ).json()
                self.assertEqual(len(ctx_win["messages"]), 1)
                self.assertEqual(ctx_win["messages"][0]["id"], pt["id"])
                self.assertNotIn("bot", ctx_win["messages"][0])
                self.assertIn("发布检查表", ctx_win["messages"][0]["text"])
                self.assertEqual(ctx_win["body"]["source_id"], synced_proactive["source_id"])

                proactive_out = await client.post(
                    "/momo/internal/superagent/outbound",
                    headers=bridge_headers,
                    json={
                        "id": "proactive-reply-9",
                        "kind": "reply",
                        "channel": {"source": "momo", "id": pt["thread_id"], "thread": pt["thread_id"]},
                        "ticket_id": "t-proactive-9",
                        "text": "已根据你的晚间录音备忘整理好明早九点前的发布检查表：\n1. 核对版本号\n2. 跑通回归测试",
                    },
                )
                self.assertEqual(proactive_out.status, 200)

                final_msgs = await (await client.get("/momo/v1/conversation/messages", headers=auth)).json()
                # 1 seeded Hermes assistant + 1 user chat + 1 explicit reply + 1 proactive reply = 4 messages!
                self.assertEqual(len(final_msgs["data"]), 4)
                self.assertIn("发布检查表", final_msgs["data"][-1]["content"])

                # 5. Projection reconciliation handles dsh's items-based ticket/decision views and ended outcomes.
                op_cancel = str(uuid.uuid4())
                cancel_receipt = await (
                    await client.post(
                        "/momo/v1/conversation/messages",
                        headers=auth,
                        json={"operation_id": op_cancel, "content": "先起草一份长报告"},
                    )
                ).json()
                cancel_run_id = cancel_receipt["run_id"]
                gateway._apply_dsh_projections(
                    {"health": {"runtime": {"state": "ready"}}},
                    [
                        {"id": "t-stop-1", "state": "ended", "ended": {"outcome": "stopped"}},
                        {"id": "t-open-proactive", "title": "核对 12 席位年付报价", "state": "open", "stage": "working", "strength": "inferred", "actions": {"stop": True}},
                        {"id": "t-queued-chat", "title": "检索上周架构纪要", "state": "open", "stage": "working", "action": "queued", "strength": "explicit", "actions": {"stop": True}},
                    ],
                    [{"id": "d-stop-1", "kind": "accept", "ticketId": "t-stop-1", "triggerIds": [f"momo:user-{op_cancel}"]}],
                )
                runs_after_stop = await (await client.get("/momo/v1/conversation/runs", headers=auth)).json()
                stopped_entry = next(r for r in runs_after_stop["data"] if r["run_id"] == cancel_run_id)
                self.assertEqual(stopped_entry["status"], "cancelled")
                bg_items = {w["id"]: w for w in runs_after_stop["background_work"]}
                self.assertNotIn("superagent:t-stop-1", bg_items)
                self.assertEqual(bg_items["superagent:t-open-proactive"]["state"], "running")
                self.assertEqual(bg_items["superagent:t-open-proactive"]["native_state"], "proactive:working")
                self.assertEqual(bg_items["superagent:t-queued-chat"]["state"], "queued")
                cancel_bg = await (
                    await client.post(
                        "/momo/v1/conversation/work/superagent:t-open-proactive/cancel",
                        headers=auth,
                        json={"operation_id": str(uuid.uuid4()), "execution_generation": 1},
                    )
                ).json()
                self.assertEqual(cancel_bg["state"], "cancelled")
                runs_after_bg_cancel = await (await client.get("/momo/v1/conversation/runs", headers=auth)).json()
                self.assertEqual([w["id"] for w in runs_after_bg_cancel["background_work"]], ["superagent:t-queued-chat"])

                # 6. Streaming ASR revisions coalesce across settle window until settled or marked ended_at.
                stream_sess = str(uuid.uuid4())
                cstore = ContextStore(data / "context")
                try:
                    p1 = make_source_payload("计费模块核对", ["咱们看一下 billing.py 里的年付折扣系数"], session_id=stream_sess)
                    cstore.sync_source(p1)
                finally:
                    cstore.close()

                # Fresh streaming ping within settle window holds watermark (0 triggers emitted mid-thought).
                held = await (
                    await client.post("/momo/v1/proactive/ingest", headers=auth, json={"origin": "source_sync"})
                ).json()
                self.assertEqual(held["count"], 0)

                # Second span arrives and marks ended_at -> flushes both spans together as a single coherent trigger!
                cstore = ContextStore(data / "context")
                try:
                    p2 = make_source_payload(
                        "计费模块核对",
                        ["咱们看一下 billing.py 里的年付折扣系数", "定下来统一改成 0.80 并跑通单测"],
                        session_id=stream_sess,
                    )
                    p2["version"] = 2
                    p2["ended_at"] = 1761897630.0
                    synced_stream = cstore.sync_source(p2)
                finally:
                    cstore.close()

                flushed = await (
                    await client.post("/momo/v1/proactive/ingest", headers=auth, json={"origin": "source_sync"})
                ).json()
                self.assertEqual(flushed["count"], 1)
                polled3 = await (
                    await client.get(f"/momo/internal/superagent/triggers?after={polled2['next_cursor']}", headers=bridge_headers)
                ).json()
                coalesced_events = [e for e in polled3["events"] if e.get("source_id") == synced_stream["source_id"]]
                self.assertEqual(len(coalesced_events), 1)
                self.assertIn("billing.py", coalesced_events[0]["text"])
                self.assertIn("0.80", coalesced_events[0]["text"])

                # 7. Long recordings (>300 spans) preserve trigger text in thread context without 120-span truncation.
                long_sess = str(uuid.uuid4())
                long_texts = [f"前段闲聊第 {i} 句：嗯" for i in range(260)]
                long_texts.append("刚才定下来把 pricing_config.json 里的试用额度统一改成 200。")
                cstore = ContextStore(data / "context")
                try:
                    p_long = make_source_payload("超长评审录音", long_texts, session_id=long_sess)
                    p_long["ended_at"] = 1761905000.0
                    synced_long = cstore.sync_source(p_long)
                finally:
                    cstore.close()

                await client.post("/momo/v1/proactive/ingest", headers=auth, json={})
                polled_long = await (
                    await client.get(f"/momo/internal/superagent/triggers?after={polled3['next_cursor']}", headers=bridge_headers)
                ).json()
                long_trig = next(e for e in polled_long["events"] if e.get("source_id") == synced_long["source_id"])
                long_ctx = await (
                    await client.get(
                        f"/momo/internal/superagent/context?thread_id={long_trig['thread_id']}&message_id={long_trig['id']}&source_id={synced_long['source_id']}",
                        headers=bridge_headers,
                    )
                ).json()
                matched_msg = next((m for m in long_ctx["messages"] if m["id"] == long_trig["id"]), None)
                self.assertIsNotNone(matched_msg)
                self.assertIn("pricing_config.json", matched_msg["text"])
                self.assertIn("200", matched_msg["text"])

                # 8. Unpolled transcript micro-triggers coalesce cleanly while preserving monotonic seq.
                sid_backlog = "lib/backlog-rec"
                for idx in range(5):
                    gateway.bridge.enqueue_trigger(
                        trigger_id=f"momo:transcript:{sid_backlog}:rev{idx}",
                        kind="transcripts",
                        thread_id=f"transcript:{sid_backlog}",
                        message_id=f"transcript:{sid_backlog}:rev{idx}",
                        source_id=sid_backlog,
                        title="积压录音",
                        addressed=False,
                        observed=True,
                        text=f"[MoMo 同步录音转写 | source_id={sid_backlog} | 标题=积压录音]\n[20:0{idx}:00] 第 {idx} 段讨论内容",
                    )
                merged_count = gateway.bridge.coalesce_unpolled_transcripts(max_chars=2400)
                self.assertEqual(merged_count, 4)
                polled_backlog = await (
                    await client.get(f"/momo/internal/superagent/triggers?after={polled_long['next_cursor']}", headers=bridge_headers)
                ).json()
                backlog_events = [e for e in polled_backlog["events"] if e.get("source_id") == sid_backlog]
                self.assertEqual(len(backlog_events), 1)
                for idx in range(5):
                    self.assertIn(f"第 {idx} 段讨论内容", backlog_events[0]["text"])

                # 9. Non-append revision updates (diarization / summary / speaker re-segmentation with no newer recorded_at)
                #    advance watermarks silently and emit ZERO duplicate historical triggers; cross-day triggers include explicit dates.
                self.assertIn("录音时间=", pt["text"])
                self.assertIn("当前时间=", pt["text"])
                self.assertIn("[日期参考：本段录音记录于", pt["text"])
                self.assertEqual(pt["at"], "2025-10-31T08:00:00Z")
                self.assertTrue(pt["thread_id"].startswith(f"transcript:{synced_proactive['source_id']}:w"))

                cstore = ContextStore(data / "context")
                try:
                    diarized_payload = make_source_payload(
                        "晚间备忘（已说话人分离）",
                        ["备忘一下：", "明早九点前把发布检查表整理出来。"],
                    )
                    # Keep session_id identical and span timestamps <= original 1761897600.0 so this is a pure diarization re-segmentation!
                    src_uuid = synced_proactive["source_id"].split("/", 1)[1]
                    diarized_payload["session_id"] = src_uuid
                    diarized_payload["version"] = 2
                    diarized_payload["ended_at"] = 1761897600.0
                    diarized_payload["spans"][0]["recorded_at"] = 1761897595.0
                    diarized_payload["spans"][0]["speaker"] = "Speaker 1"
                    diarized_payload["spans"][1]["recorded_at"] = 1761897600.0
                    diarized_payload["spans"][1]["speaker"] = "Speaker 1"
                    cstore.sync_source(diarized_payload)
                finally:
                    cstore.close()

                re_ingested = await (await client.post("/momo/v1/proactive/ingest", headers=auth, json={})).json()
                self.assertEqual(re_ingested["count"], 0)

                # Ended ticket on the same 5-minute window forces next window suffix (:r2) instead of zombie-reopening ended ticket.
                gateway._cached_tickets = [
                    {
                        "id": "t-ended-old",
                        "title": "旧录音核查",
                        "state": "ended",
                        "ended": {"outcome": "dropped", "at": "2026-11-01T10:05:00Z", "reason": "历史沟通事项已过时"},
                        "threads": [f"momo:{pt['thread_id']}"],
                        "strength": "inferred",
                        "createdAt": "2026-11-01T10:00:00Z",
                        "updatedAt": "2026-11-01T10:05:00Z",
                        "summary": "核查后续记录发现该事项已在昨日完成，静默跳过。",
                    },
                    {
                        "id": "t-live-worker",
                        "title": "整理 Q4 架构评审纪要",
                        "state": "open",
                        "stage": "working",
                        "strength": "inferred",
                        "threads": [f"momo:{pt['thread_id']}:r2"],
                        "createdAt": "2026-11-03T04:10:00Z",
                        "updatedAt": "2026-11-03T04:12:00Z",
                        "mandate": {"strength": "inferred", "scope": "核查录音中的 Q4 架构改动清单并生成评审纪要草稿"},
                        "decision": {
                            "outcome": "accept",
                            "rules": [{"id": "r1", "name": "明确备忘与交付物起草", "matched": True}],
                            "triggerIds": [f"momo:{pt['id']}"],
                        },
                        "actions": {"stop": True},
                    },
                ]

                cstore = ContextStore(data / "context")
                try:
                    appended_payload = dict(diarized_payload)
                    appended_payload["version"] = 3
                    appended_payload["spans"] = [
                        *diarized_payload["spans"],
                        {"id": str(uuid.uuid4()), "text": "再补一句：把灰度回滚脚本也记上。", "recorded_at": 1761897620.0},
                    ]
                    appended_payload["text_sha256"] = digest("\n".join(s["text"] for s in appended_payload["spans"]))
                    cstore.sync_source(appended_payload)
                finally:
                    cstore.close()

                appended_ingested = await (await client.post("/momo/v1/proactive/ingest", headers=auth, json={})).json()
                self.assertEqual(appended_ingested["count"], 1)
                polled_appended = await (
                    await client.get(f"/momo/internal/superagent/triggers?after={polled_backlog['next_cursor']}", headers=bridge_headers)
                ).json()
                self.assertTrue(polled_appended["events"][0]["thread_id"].endswith(":r2"))

                # 10. Task overview (/works) & live task detail (/work/{id}) decompress zstd worker logs cleanly.
                from compression import zstd

                worker_dir = data / "superagent/dsh-home/sessions/2026-11-03/worker-t-live-worker"
                worker_dir.mkdir(parents=True, exist_ok=True)
                sample_events = [
                    {"type": "session", "version": 4, "id": "worker-t-live-worker", "cwd": str(data / "superagent/work/q4-review")},
                    {"type": "turn/start", "seq": 1, "time": 1793611800000, "data": {"turn": 1}},
                    {"type": "step/start", "seq": 2, "time": 1793611801000, "data": {"turn": 1, "step": 1}},
                    {
                        "type": "tool/call",
                        "seq": 3,
                        "time": 1793611802000,
                        "data": {
                            "turn": 1,
                            "step": 1,
                            "callId": "call-todo",
                            "name": "todo_write",
                            "arguments": json.dumps(
                                {
                                    "todos": [
                                        {"id": "1", "content": "读取完整录音与后续聊天记录", "status": "completed"},
                                        {"id": "2", "content": "输出 Q4 架构评审纪要草稿", "status": "in_progress"},
                                    ]
                                },
                                ensure_ascii=False,
                            ),
                        },
                    },
                    {
                        "type": "tool/call",
                        "seq": 4,
                        "time": 1793611803000,
                        "data": {
                            "turn": 1,
                            "step": 1,
                            "callId": "call-bash-1",
                            "name": "bash",
                            "arguments": json.dumps(
                                {
                                    "description": "核查源录音完整原文与近期记录",
                                    "command": '"$DSH_SUPERAGENT_MOMO_CLI" recordings --limit 10',
                                },
                                ensure_ascii=False,
                            ),
                        },
                    },
                    {
                        "type": "tool/result",
                        "seq": 5,
                        "time": 1793611804000,
                        "data": {"message": {"toolCallId": "call-bash-1", "isError": False}},
                    },
                    {
                        "type": "tool/call",
                        "seq": 6,
                        "time": 1793611805000,
                        "data": {
                            "turn": 1,
                            "step": 2,
                            "callId": "call-sub-1",
                            "name": "subagent",
                            "arguments": json.dumps(
                                {"role": "代码核查子代理", "prompt": "核对网关路由与单测覆盖情况"},
                                ensure_ascii=False,
                            ),
                        },
                    },
                ]
                jsonl_bytes = ("\n".join(json.dumps(ev, ensure_ascii=False) for ev in sample_events) + "\n").encode("utf-8")
                (worker_dir / "session.v4.jsonl.zstd").write_bytes(zstd.compress(jsonl_bytes))

                works_overview = await (await client.get("/momo/v1/conversation/works?limit=10", headers=auth)).json()
                self.assertEqual([w["id"] for w in works_overview["active"]], ["superagent:t-live-worker"])
                self.assertEqual([w["id"] for w in works_overview["recent"]], ["superagent:t-ended-old"])
                self.assertEqual(works_overview["recent"][0]["state"], "dropped")

                detail_resp = await client.get("/momo/v1/conversation/work/superagent%3At-live-worker", headers=auth)
                self.assertEqual(detail_resp.status, 200)
                detail = await detail_resp.json()
                self.assertEqual(detail["title"], "整理 Q4 架构评审纪要")
                self.assertEqual(detail["origin_kind"], "proactive_transcript")
                self.assertEqual(detail["origin_label"], "录音主动派发")
                self.assertEqual(detail["scope"], "核查录音中的 Q4 架构改动清单并生成评审纪要草稿")
                self.assertEqual(detail["matched_rules"], ["明确备忘与交付物起草"])
                self.assertIsNotNone(detail["source_recorded_at"])
                self.assertEqual(detail["turn_count"], 1)
                self.assertEqual(len(detail["todos"]), 2)
                self.assertEqual(len(detail["activities"]), 2)
                self.assertEqual(detail["activities"][0]["title"], "核查源录音完整原文与近期记录")
                self.assertEqual(detail["activities"][0]["status"], "completed")
                self.assertIn("momo-cli recordings", detail["activities"][0]["detail"])
                self.assertEqual(detail["activities"][1]["kind"], "subagent")
                self.assertEqual(detail["activities"][1]["status"], "running")

                # 11. Real dsh TicketList (int counts + dict threads) & explicit-routed TicketDetail schema.
                raw_uuid_sid = f"dev-uuid/{uuid.uuid4()}"
                gateway.bridge.enqueue_trigger(
                    trigger_id=f"momo:transcript:{raw_uuid_sid}:0:1:abc",
                    kind="transcripts",
                    thread_id=f"transcript:{raw_uuid_sid}",
                    message_id=f"transcript:{raw_uuid_sid}:0:1:abc",
                    source_id=raw_uuid_sid,
                    title=raw_uuid_sid,
                    addressed=False,
                    observed=True,
                    text=f"[MoMo 同步录音转写 | source_id={raw_uuid_sid}]\n[2026-10-30 16:40:04] 按主分支官网整理设计参数",
                )
                gateway._cached_tickets = [
                    {
                        "id": "t-real-dsh-explicit",
                        "title": "按当前主分支官网提取设计参数",
                        "state": "ended",
                        "stage": "ended",
                        "strength": "explicit",
                        "ended": {"at": "2026-11-03T04:27:01.996Z", "by": "executor", "outcome": "dropped"},
                        "assignments": 59,
                        "inputs": 155,
                        "undelivered": 0,
                        "threads": [
                            {
                                "key": f"momo:transcript:{raw_uuid_sid}",
                                "source": "momo",
                                "title": raw_uuid_sid,
                                "facts": {},
                            }
                        ],
                        "mandate": {
                            "strength": "explicit",
                            "basis": {
                                "source": "momo",
                                "scope": {
                                    "stream": "transcripts",
                                    "messageId": f"transcript:{raw_uuid_sid}:0:1:abc",
                                    "threadId": f"transcript:{raw_uuid_sid}",
                                    "sourceId": raw_uuid_sid,
                                    "title": raw_uuid_sid,
                                },
                            },
                        },
                        "decision": {
                            "kind": "accept",
                            "outcome": "accept",
                            "reason": [{"code": "explicitRouted"}],
                            "triggerIds": [f"momo:transcript:{raw_uuid_sid}:0:1:abc"],
                            "thread": f"momo:transcript:{raw_uuid_sid}",
                            "rules": [],
                        },
                        "createdAt": "2026-11-02T09:36:37.244Z",
                        "updatedAt": "2026-11-03T04:27:01.996Z",
                    }
                ]
                real_works_resp = await client.get("/momo/v1/conversation/works?limit=10", headers=auth)
                self.assertEqual(real_works_resp.status, 200)
                real_works = await real_works_resp.json()
                self.assertEqual(len(real_works["recent"]), 1)
                self.assertEqual(real_works["recent"][0]["id"], "superagent:t-real-dsh-explicit")
                self.assertEqual(real_works["recent"][0]["origin_kind"], "proactive_transcript")
                self.assertEqual(real_works["recent"][0]["origin_label"], "录音主动派发")
                self.assertIsNotNone(real_works["recent"][0]["source_recorded_at"])

                real_detail_resp = await client.get(
                    "/momo/v1/conversation/work/superagent%3At-real-dsh-explicit", headers=auth
                )
                self.assertEqual(real_detail_resp.status, 200)
                real_detail = await real_detail_resp.json()
                self.assertEqual(real_detail["scope"], "编排器显式路由派发")
                self.assertEqual(real_detail["origin_label"], "录音主动派发")
                self.assertIsNone(real_detail["source_title"])  # Raw UUID fallback suppressed when title == source_id
                self.assertIn("按主分支官网整理设计参数", real_detail["trigger_preview"])
                self.assertEqual(
                    gateway._thread_keys(gateway._cached_tickets[0]["threads"]),
                    [f"momo:transcript:{raw_uuid_sid}"],
                )
            finally:
                await client.close()


if __name__ == "__main__":
    unittest.main()
