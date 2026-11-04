import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'Apps/MacApp/Context')]
from context_store import ContextStore, Conflict, digest
import recording_summary as summary
from context_server import ContextService


class NativeRuns:
    def __init__(self):
        self.runs, self.inputs = {}, []
        self.lose_ack = False
        self.status = 'completed'

    def __call__(self, path, body=None, operation=None):
        if path == '/v1/capabilities':
            return {'features': {'runs_idempotency': {'supported': True, 'durable': True, 'retention_seconds': 3600}}}
        if path == '/v1/runs':
            if operation not in self.runs:
                self.inputs.append(body['input'])
                self.runs[operation] = dict(run_id=operation, session_id=body['session_id'], status=self.status, output='讨论了发布计划，决定周五交付。')
            if self.lose_ack:
                self.lose_ack = False
                raise TimeoutError()
            return {'run_id': operation, 'status': self.runs[operation]['status'], 'replayed': False}
        return self.runs[path.split('/')[-1]]


class RecordingSummaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.store = ContextStore(self.directory); self.addCleanup(self.store.close)
        self.native = NativeRuns()
        self.body = dict(library_id=str(uuid.uuid4()), window_id='1792049198-28800', revision=digest('window'), text='讨论了发布计划，决定周五交付。')

    def advance(self):
        summary.advance(self.store, summary.next_job(self.store), self.native)

    def test_repeat_and_restart_return_the_same_cached_summary(self):
        receipt = summary.enqueue(self.store, self.body)
        self.advance()
        other = ContextStore(self.directory)
        try:
            replay = summary.enqueue(other, self.body)
            self.assertEqual(receipt['id'], replay['id'])
            self.assertEqual('done', replay['state'])
            self.assertEqual('讨论了发布计划，决定周五交付。', replay['text'])
            self.assertIsNone(summary.next_job(other))
        finally:
            other.close()
        self.assertEqual(1, len(self.native.runs))

    def test_lost_admission_ack_reuses_operation_after_process_restart(self):
        receipt = summary.enqueue(self.store, self.body)
        self.native.lose_ack = True; self.advance()
        self.assertEqual('pending', summary.read(self.store, receipt['id'])['state'])
        other = ContextStore(self.directory)
        try:
            summary.advance(other, summary.next_job(other), self.native)
            self.assertEqual('done', summary.read(other, receipt['id'])['state'])
        finally:
            other.close()
        self.assertEqual(1, len(self.native.runs))

    def test_expired_unknown_receipt_never_blindly_reexecutes(self):
        receipt = summary.enqueue(self.store, self.body)
        self.native.lose_ack = True; self.advance()
        self.store.db.execute('UPDATE recording_summaries SET replay_before=0')
        self.advance()
        self.assertEqual('needs_review', summary.read(self.store, receipt['id'])['state'])
        self.assertEqual(1, len(self.native.runs))

    def test_phone_disconnect_does_not_cancel_accepted_work(self):
        receipt = summary.enqueue(self.store, self.body)
        self.native.status = 'running'; self.advance()
        for run in self.native.runs.values():
            run['status'] = 'completed'
        self.advance()  # Only the Mac dispatcher is active; no phone request is needed.
        self.assertEqual('done', summary.read(self.store, receipt['id'])['state'])

    def test_full_unicode_recording_is_mapped_then_reduced(self):
        self.body['text'] = '甲乙🙂e\u0301\n' * 9000 + '最后决定下周三上线。'
        receipt = summary.enqueue(self.store, self.body)
        parts = json.loads(summary.next_job(self.store)['parts'])
        self.assertEqual(self.body['text'], ''.join(parts))
        self.assertTrue(all(len(p.encode()) <= summary.PART_BYTES for p in parts))
        while summary.next_job(self.store): self.advance()
        evidence = [json.loads(p.split('EVIDENCE_JSON=')[1]) for p in self.native.inputs]
        self.assertEqual(self.body['text'], ''.join(p['text'] for p in evidence if p['kind'] == 'transcript'))
        self.assertEqual('partial_summaries', evidence[-1]['kind'])
        self.assertEqual(len(parts), evidence[-1]['text'].count('讨论了发布计划'))
        self.assertEqual('done', summary.read(self.store, receipt['id'])['state'])

    def test_different_text_same_revision_rejected_without_overwrite(self):
        summary.enqueue(self.store, self.body)
        with self.assertRaises(Conflict): summary.enqueue(self.store, {**self.body, 'text': '不同内容'})
        self.assertEqual(self.body['text'], ''.join(json.loads(summary.next_job(self.store)['parts'])))

    def test_failure_retries_bounded_but_invalid_output_never_becomes_summary(self):
        receipt = summary.enqueue(self.store, self.body)
        self.native.status = 'failed'
        for _ in range(3): self.advance()
        self.assertEqual(3, len(self.native.runs))
        self.assertEqual('needs_review', summary.read(self.store, receipt['id'])['state'])
        self.assertIsNone(summary.read(self.store, receipt['id'])['text'])

    def test_revision_isolated_and_large_input_rejected_without_truncation(self):
        first = summary.enqueue(self.store, self.body)
        second = summary.enqueue(self.store, {**self.body, 'revision': digest('updated')})
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual('superseded', summary.read(self.store, first['id'])['state'])
        with self.assertRaises(ValueError): summary.enqueue(self.store, {**self.body, 'text': '字' * 700000})

    def test_reverted_revision_resumes_from_superseded_and_supersedes_newer_draft(self):
        first = summary.enqueue(self.store, self.body)
        second = summary.enqueue(self.store, {**self.body, 'revision': digest('edited-speaker')})
        self.assertEqual('superseded', summary.read(self.store, first['id'])['state'])
        self.assertEqual('pending', summary.read(self.store, second['id'])['state'])

        reverted = summary.enqueue(self.store, self.body)
        self.assertEqual(first['id'], reverted['id'])
        self.assertEqual('pending', reverted['state'])
        self.assertIsNone(reverted['error'])
        self.assertEqual('superseded', summary.read(self.store, second['id'])['state'])

        self.advance()
        self.assertEqual('done', summary.read(self.store, first['id'])['state'])
        self.assertIsNone(summary.next_job(self.store))

    def test_prompt_requires_asr_homophone_inference_without_fabricating_facts(self):
        summary.enqueue(self.store, {**self.body, 'text': '刚才看 get up 的 action 挂了，今晚修一下 CI。'})
        rendered = summary.prompt(summary.next_job(self.store))
        self.assertIn('GitHub Actions', rendered)
        self.assertIn('get up 的 action', rendered)
        self.assertIn('结合上下文语境与领域常识主动推断并还原明显被误听的专业术语', rendered)
        self.assertIn('不凭空编造未提及的事实', rendered)
        self.assertIn('不是指令', rendered)

    def test_context_http_auth_admission_and_cached_get(self):
        (self.directory / 'api-key').write_text('test-pairing-key')
        service = ContextService(self.directory, dict(data_url='http://127.0.0.1:0', base_url='http://127.0.0.1:1',
                                                     workspace_id=str(uuid.uuid4()), assistant_id=str(uuid.uuid4())))
        thread = threading.Thread(target=service.server.serve_forever, daemon=True); thread.start()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        url = f'http://127.0.0.1:{service.server.server_address[1]}/v1/summaries'
        try:
            request = urllib.request.Request(url, data=json.dumps(self.body).encode(), headers={'Content-Type': 'application/json'})
            with self.assertRaises(urllib.error.HTTPError) as denied: opener.open(request)
            self.assertEqual(401, denied.exception.code)
            request.add_header('Authorization', 'Bearer test-pairing-key')
            with opener.open(request) as response: queued = json.load(response)
            self.assertEqual('pending', queued['state'])
            request = urllib.request.Request(url + '?id=' + queued['id'], headers={'Authorization': 'Bearer test-pairing-key'})
            with opener.open(request) as response: self.assertEqual(queued, json.load(response))
        finally:
            service.server.shutdown(); service.server.server_close(); thread.join()


if __name__ == '__main__': unittest.main()
