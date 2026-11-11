from __future__ import annotations

import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from aiohttp.test_utils import TestClient, TestServer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Apps/MacApp/Runtime"))
sys.path.insert(0, str(ROOT / "Apps/MacApp/Context"))
sys.path.insert(0, str(ROOT / "Apps/MacApp/Access"))

from apple_pim import ApplePIM, PIM_OPS  # noqa: E402
from conversation_store import collect_deliverable_attachments  # noqa: E402
import momo_agent  # noqa: E402
import momo_cli  # noqa: E402
import pim_mcp  # noqa: E402
from superagent_gateway import SuperAgentGateway  # noqa: E402


class ApplePIMTests(unittest.IsolatedAsyncioTestCase):
    async def test_receipt_wrapping_for_reminders_events_and_notes(self) -> None:
        calls: list[tuple[str, dict]] = []

        def fake_transport(op: str, args: dict) -> dict:
            calls.append((op, args))
            if op == "search_reminders":
                return {"ok": True, "items": [{"id": "rem-1", "title": "发合同", "completed": False}], "count": 1}
            if op == "create_reminder":
                return {
                    "ok": True,
                    "state": "succeeded",
                    "item": {
                        "id": "rem-2",
                        "title": args["title"],
                        "list_name": args.get("list_name", "提醒事项"),
                        "completed": False,
                        "due_at": args.get("due_at"),
                    },
                }
            if op == "complete_reminder":
                return {
                    "ok": True,
                    "actionID": "native-action-123",
                    "state": "succeeded",
                    "resource": {
                        "kind": "reminder",
                        "id": args["reminder_id"],
                        "fields": {"title": "发合同", "completed": True},
                    },
                }
            if op == "create_calendar_event":
                return {
                    "ok": True,
                    "state": "succeeded",
                    "item": {
                        "id": "evt-1",
                        "title": args["title"],
                        "start_at": args["start_at"],
                        "end_at": args["end_at"],
                        "calendar_name": "工作",
                    },
                }
            if op == "create_note":
                return {
                    "ok": True,
                    "state": "succeeded",
                    "item": {
                        "id": "note-1",
                        "title": args["title"],
                        "folder": "备忘录",
                    },
                }
            if op == "delete_reminder":
                return {"ok": False, "state": "needs_permission", "error": "缺少提醒事项权限"}
            return {"ok": True}

        with tempfile.TemporaryDirectory() as tmp:
            pim = ApplePIM(Path(tmp), transport=fake_transport)

            searched = await pim.call("search_reminders", {"query": "合同", "limit": None})
            self.assertEqual(searched["count"], 1)
            self.assertNotIn("actionID", searched)
            self.assertEqual(calls[-1], ("search_reminders", {"query": "合同"}))

            created_rem = await pim.call(
                "create_reminder",
                {"title": "周五前给法务发 NDA", "due_at": "2026-11-06T18:00:00+08:00", "list_name": "工作"},
            )
            self.assertTrue(created_rem["ok"])
            self.assertEqual(created_rem["state"], "succeeded")
            self.assertEqual(created_rem["resource"]["kind"], "reminder")
            self.assertEqual(created_rem["resource"]["id"], "rem-2")
            self.assertEqual(created_rem["resource"]["fields"]["title"], "周五前给法务发 NDA")
            self.assertEqual(created_rem["resource"]["fields"]["list"], "工作")
            self.assertEqual(created_rem["resource"]["fields"]["dueAt"], "2026-11-06T18:00:00+08:00")

            native_passthrough = await pim.call("complete_reminder", {"reminder_id": "rem-1"})
            self.assertEqual(native_passthrough["actionID"], "native-action-123")
            self.assertTrue(native_passthrough["resource"]["fields"]["completed"])

            created_evt = await pim.call(
                "create_calendar_event",
                {
                    "title": "产品设计评审",
                    "start_at": "2026-11-05T15:00:00+08:00",
                    "end_at": "2026-11-05T16:00:00+08:00",
                },
            )
            self.assertEqual(created_evt["resource"]["kind"], "event")
            self.assertEqual(created_evt["resource"]["fields"]["calendar"], "工作")

            created_note = await pim.call("create_note", {"title": "周会灵感清单", "body": "1. 优化记忆总结"})
            self.assertEqual(created_note["resource"]["kind"], "note")
            self.assertEqual(created_note["resource"]["fields"]["folder"], "备忘录")

            denied = await pim.call("delete_reminder", {"reminder_id": "rem-9"})
            self.assertFalse(denied["ok"])
            self.assertEqual(denied["state"], "needs_permission")
            self.assertEqual(denied["resource"]["kind"], "reminder")

            with self.assertRaises(ValueError):
                await pim.call("drop_database", {})

    def test_mcp_exposes_all_pim_operations_and_cli_subcommand(self) -> None:
        self.assertEqual(len(PIM_OPS), 19)
        registered = {tool.name for tool in pim_mcp.server._tool_manager.list_tools()}
        self.assertEqual(registered, set(PIM_OPS))

        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "Agent"
            data.mkdir(parents=True)
            with mock.patch.object(
                ApplePIM,
                "call_sync",
                return_value={"ok": True, "lists": [{"id": "l1", "title": "提醒事项", "is_default": True}]},
            ) as mocked_call:
                buf = io.StringIO()
                with mock.patch(
                    "sys.argv",
                    ["momo_cli.py", "--data-dir", str(data), "pim", "list_reminder_lists", "--args-json", "{}"],
                ), mock.patch("sys.stdout", buf):
                    rc = momo_cli.main()
                self.assertEqual(rc or 0, 0)
                mocked_call.assert_called_once_with("list_reminder_lists", {})
                parsed = json.loads(buf.getvalue())
                self.assertEqual(parsed["lists"][0]["title"], "提醒事项")

    async def test_superagent_pim_endpoint_and_space_path_outbound_cleaning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            # Simulate ~/Library/Application Support/MoMoAgent/Agent containing a space in directory name!
            data = Path(tmp) / "Application Support/MoMoAgent/Agent"
            conn = momo_agent.initialize(data, 19839)
            api_key = (data / "api-key").read_text(encoding="utf-8").strip()
            gateway = SuperAgentGateway(
                data,
                conn,
                python_executable=Path(sys.executable),
                base_env={},
                manage_dsh=False,
            )
            gateway.pim = ApplePIM(
                data,
                transport=lambda op, args: {
                    "ok": True,
                    "state": "succeeded",
                    "item": {"id": "rem-live-1", "title": args.get("title", ""), "completed": False, "list_name": "待办"},
                },
            )
            client = TestClient(TestServer(gateway.create_app()))
            await client.start_server()
            try:
                auth = {"Authorization": f"Bearer {api_key}"}
                bridge_headers = {"X-MoMo-Bridge": gateway.bridge_secret}

                # 1. Missing bridge secret is rejected with 403.
                unauth = await client.post(
                    "/momo/internal/superagent/pim",
                    json={"op": "create_reminder", "args": {"title": "测试"}},
                )
                self.assertEqual(unauth.status, 403)

                # 2. Valid internal PIM call returns structured receipt.
                ok_resp = await client.post(
                    "/momo/internal/superagent/pim",
                    headers=bridge_headers,
                    json={"op": "create_reminder", "args": {"title": "明早十点给盛立发纪要"}},
                )
                self.assertEqual(ok_resp.status, 200)
                ok_json = await ok_resp.json()
                self.assertEqual(ok_json["state"], "succeeded")
                self.assertEqual(ok_json["resource"]["kind"], "reminder")
                self.assertEqual(ok_json["resource"]["fields"]["title"], "明早十点给盛立发纪要")

                # 3. When dsh_ready=True, live open tickets succeed while stale/stopped/paused tickets are rejected with 409.
                gateway.dsh_ready = True
                with mock.patch.object(
                    gateway,
                    "_computer_ticket",
                    return_value={
                        "id": "tkt_open",
                        "state": "open",
                        "action": "running",
                        "ended": None,
                        "paused": False,
                        "attention": None,
                        "assignments": [{"id": "asg_live", "state": "running", "endedAt": None}],
                    },
                ):
                    live_open_resp = await client.post(
                        "/momo/internal/superagent/pim",
                        headers=bridge_headers,
                        json={
                            "ticket_id": "tkt_open",
                            "assignment_id": "asg_live",
                            "op": "create_reminder",
                            "args": {"title": "活跃开放工单正常调用"},
                        },
                    )
                    self.assertEqual(live_open_resp.status, 200)

                with mock.patch.object(
                    gateway,
                    "_computer_ticket",
                    return_value={"id": "tkt_1", "state": "ended", "assignments": []},
                ):
                    stale_resp = await client.post(
                        "/momo/internal/superagent/pim",
                        headers=bridge_headers,
                        json={
                            "ticket_id": "tkt_1",
                            "assignment_id": "asg_1",
                            "op": "create_reminder",
                            "args": {"title": "不应写入"},
                        },
                    )
                    self.assertEqual(stale_resp.status, 409)

                # 3b. Open ticket with transient transport failure ("LlmError: Connection error.") auto-retries and reopens chat_run.
                gateway.bridge.db.execute(
                    """INSERT INTO chat_runs(
                           run_id, operation_id, session_id, work_id, title, status,
                           ticket_id, error, intent, cancellable, created_at, updated_at
                       ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        "run_recover_1",
                        "op_recover_1",
                        gateway.store.identity["root"],
                        "work_recover_1",
                        "纠正约瑟记忆",
                        "failed",
                        "tkt_conn_err",
                        "执行未完成，请核对已有结果。",
                        "new",
                        0,
                        1000.0,
                        1005.0,
                    ),
                )
                gateway.bridge.db.commit()
                retried_calls: list[str] = []
                with mock.patch(
                    "superagent_gateway.dsh_api_request",
                    side_effect=lambda port, method, path, payload=None, timeout=8.0: (retried_calls.append(path) or {}),
                ):
                    gateway._recover_interrupted_tickets(
                        {"paused": False},
                        [
                            {
                                "id": "tkt_conn_err",
                                "state": "open",
                                "action": "failed",
                                "ended": None,
                                "attention": None,
                                "actions": {"retry": True},
                                "summary": "LlmError: Connection error.",
                                "updatedAt": "2026-11-11T12:46:00.000Z",
                            },
                            {
                                "id": "tkt_quota_err",
                                "state": "open",
                                "action": "failed",
                                "ended": None,
                                "attention": None,
                                "actions": {"retry": True},
                                "summary": "Error code: 429 - insufficient_quota: exceeded your current quota",
                                "updatedAt": "2026-11-11T12:46:00.000Z",
                            },
                        ],
                    )
                self.assertEqual(retried_calls, ["/orchestrator/api/tickets/tkt_conn_err/retry"])
                recovered_row = gateway.bridge.db.execute(
                    "SELECT status, error, cancellable FROM chat_runs WHERE run_id='run_recover_1'"
                ).fetchone()
                self.assertEqual(recovered_row["status"], "started")
                self.assertIsNone(recovered_row["error"])
                self.assertEqual(recovered_row["cancellable"], 1)
                gateway.dsh_ready = False

                # 4. Space-containing Application Support deliverable path is collected AND stripped from chat bubble!
                ticket_dir = data / "workspace/todo-summary-tkt_clean01"
                ticket_dir.mkdir(parents=True, exist_ok=True)
                report_path = ticket_dir / "架构对比卡片.html"
                report_path.write_text("<!doctype html><html><body><h1>对比</h1></body></html>", encoding="utf-8")

                atts = collect_deliverable_attachments(
                    f"完整文件见 `{report_path}`。",
                    allowed_roots=[data / "workspace"],
                    source_key="space-test",
                )
                self.assertIsNotNone(atts)
                self.assertEqual([a["name"] for a in atts], ["架构对比卡片.html"])

                gateway._cached_tickets = [
                    {
                        "id": "tkt_clean01",
                        "name": "todo-summary-tkt_clean01",
                        "title": "架构对比",
                        "state": "open",
                        "stage": "working",
                        "strength": "inferred",
                        "threads": ["momo:transcript:src-clean:s0"],
                    }
                ]
                outbound_resp = await client.post(
                    "/momo/internal/superagent/outbound",
                    headers=bridge_headers,
                    json={
                        "id": "out-clean-space-path",
                        "kind": "reply",
                        "channel": {
                            "source": "momo",
                            "id": "transcript:src-clean:s0",
                            "thread": "transcript:src-clean:s0",
                        },
                        "ticket_id": "tkt_clean01",
                        "text": f"刚听你聊到网关选型，我顺手把两种方案的延迟对比整理好啦：{report_path}。",
                    },
                )
                self.assertEqual(outbound_resp.status, 200)
                msgs = await (await client.get("/momo/v1/conversation/messages", headers=auth)).json()
                bubble = msgs["data"][-1]
                self.assertNotIn("Application Support", bubble["content"])
                self.assertEqual(
                    bubble["content"],
                    "刚听你聊到网关选型，我顺手把两种方案的延迟对比整理好啦。",
                )
                self.assertEqual([a["name"] for a in bubble["attachments"]], ["架构对比卡片.html"])
            finally:
                await client.close()


if __name__ == "__main__":
    unittest.main()
