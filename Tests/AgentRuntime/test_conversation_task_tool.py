import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Apps/MacApp/Runtime"))
from momo_agent import initialize

spec = importlib.util.spec_from_file_location("task_control", ROOT / "Tests/AgentRuntime/fixtures/legacy_gateway/prompt_plugin/task_control.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class TaskControlTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.data = Path(temp.name); initialize(self.data, 18765)
        self.calls = []
        self.snapshot = dict(work_id="work-1", run_id="run-1", execution_generation=2, execution_session_id="earlier-user-turn")
        self.opener = patch.object(tool.urllib.request, "build_opener", return_value=self).start()
        self.addCleanup(patch.stopall)

    def open(self, request, **_):
        self.calls.append(request)
        return io.BytesIO(json.dumps(self.snapshot if "/v1/runs/" in request.full_url else {"accepted": True}).encode())

    def args(self, action="stop"):
        return dict(action=action, work_id="work-1", run_id="run-1", generation=2)

    def test_inspect_preserves_pagination_without_mutation(self):
        tool.control(self.data, dict(action="inspect", after=50), "current-user-turn")
        self.assertTrue(self.calls[0].full_url.endswith("/runs?after=50&limit=50"))
        self.assertIsNone(self.calls[0].data)

    def test_stop_is_exact_and_retries_keep_one_receipt(self):
        for _ in range(2): tool.control(self.data, self.args(), "current-user-turn")
        body = json.loads(self.calls[1].data)
        self.assertEqual(body, json.loads(self.calls[3].data))
        self.assertEqual(body["execution_generation"], 2)
        self.assertEqual(body["target_run_id"], "run-1")
        self.assertTrue(self.calls[1].full_url.endswith("/work/work-1/cancel"))
        tool.control(self.data, self.args(), "another-user-turn")
        self.assertNotEqual(body["operation_id"], json.loads(self.calls[-1].data)["operation_id"])

    def test_update_routes_to_old_work_not_a_new_execution(self):
        tool.control(self.data, {**self.args("update"), "message": "改成周五"}, "current-user-turn")
        body = json.loads(self.calls[-1].data)
        self.assertEqual((body["intent"], body["content"], body["work_id"], body["target_run_id"]), ("steer", "改成周五", "work-1", "run-1"))

    def test_queued_run_preserves_exact_target_with_generation_zero(self):
        self.snapshot["execution_generation"] = None
        tool.control(self.data, {**self.args(), "generation": 0}, "current-user-turn")
        body = json.loads(self.calls[-1].data)
        self.assertEqual((body["execution_generation"], body["target_run_id"]), (0, "run-1"))

    def test_stale_target_and_self_cancellation_do_not_write(self):
        for override in ({"execution_generation": 3}, {"work_id": "other"}, {"execution_session_id": "current-user-turn"}):
            old = self.snapshot.copy(); self.snapshot.update(override)
            result = tool.control(self.data, self.args(), "current-user-turn")
            self.assertIn("error", result); self.snapshot = old
        self.assertTrue(all(request.data is None for request in self.calls))

    def test_invalid_context_and_non_loopback_configuration_fail_closed(self):
        with self.assertRaises(ValueError): tool.control(self.data, self.args(), "")
        p = self.data / "connection.json"; value = json.loads(p.read_text()); value["base_url"] = "https://elsewhere.example"
        p.write_text(json.dumps(value))
        with self.assertRaises(ValueError): tool.control(self.data, self.args(), "current-user-turn")
        self.assertEqual(self.calls, [])


if __name__ == "__main__": unittest.main()
