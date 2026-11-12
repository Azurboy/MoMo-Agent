import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Apps/MacApp/Context"))
from context_store import ContextStore, digest, canonical
from transcript_ingestion import prepare, finish, next_job, MAX_BATCH_BYTES, MAX_PARTS
from memory_review import AUTOMATIC_INTERVAL


class TranscriptIngestionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = ContextStore(self.temp.name)
        self.source = dict(library_id=str(uuid.uuid4()), session_id=str(uuid.uuid4()), device_id=str(uuid.uuid4()),
                           generation=0, version=0, deleted=False, recorded_at=1000, spans=[])

    def tearDown(self):
        self.store.close(); self.temp.cleanup()

    def sync(self, texts):
        old = self.source["spans"]
        self.source["version"] += 1
        self.source["spans"] = [dict(id=old[i]["id"] if i < len(old) else str(uuid.uuid4()), text=text, recorded_at=1000+i) for i, text in enumerate(texts)]
        self.source["text_sha256"] = digest("\n".join(texts))
        return self.store.sync_source(self.source)

    def job(self):
        return self.store.db.execute("SELECT * FROM jobs WHERE state='pending' ORDER BY rowid LIMIT 1").fetchone()

    def test_new_text_and_corrections_only_after_restart(self):
        self.sync(["喜欢清淡", "周五发方案"])
        job = self.job(); batch = prepare(self.store, job); finish(self.store, job)
        self.store.close(); self.store = ContextStore(self.temp.name)
        self.sync(["喜欢清淡", "改为周三发方案", "聚餐未定"])
        update = prepare(self.store, self.job())
        self.assertEqual(["改为周三发方案", "聚餐未定"], [p["text"] for p in update["passages"]])
        self.assertEqual(batch["passages"][1]["id"], update["passages"][0]["id"])

    def test_long_unicode_source_drains_without_silent_truncation(self):
        texts = ["转录正文" * 3000] + [f"段落 {i}" for i in range(45)]
        self.sync(texts)
        all_parts = []; count = 0
        while job := self.job():
            batch = prepare(self.store, job); count += 1
            self.assertLessEqual(len(batch["passages"]), MAX_PARTS)
            self.assertLessEqual(len(canonical(batch["passages"]).encode()), MAX_BATCH_BYTES)
            all_parts.extend(batch["passages"]); finish(self.store, job)
            self.assertLess(count, 20)
        recovered = {}
        for part in all_parts: recovered.setdefault(part["id"].split(":")[0], []).append(part["text"])
        self.assertEqual(texts, ["".join(recovered[s["id"]]) for s in self.source["spans"]])
        self.assertGreater(count, 1)

    def test_admitted_batch_stays_fixed_and_blocks_second_writer(self):
        self.sync(["第一句"]); job = self.job(); batch = prepare(self.store, job)
        self.store.db.execute("UPDATE jobs SET state='running',run_id='native-run' WHERE id=?", (job["id"],))
        self.sync(["第一句", "新增一句"])
        self.assertEqual("running", self.store.db.execute("SELECT state FROM jobs WHERE id=?", (job["id"],)).fetchone()[0])
        saved = self.store.db.execute("SELECT * FROM jobs WHERE id=?", (job["id"],)).fetchone()
        self.assertEqual(batch, prepare(self.store, saved))
        finish(self.store, saved)
        self.assertEqual(["新增一句"], [p["text"] for p in prepare(self.store, self.job())["passages"]])

    def test_duplicate_source_creates_no_new_model_work(self):
        self.sync(["没有新增"]); job=self.job(); prepare(self.store,job); finish(self.store,job)
        self.store.sync_source(copy.deepcopy(self.source))
        self.assertIsNone(self.job())
        self.sync(["没有新增"])
        job=self.job(); self.assertEqual([],prepare(self.store,job)["passages"]); finish(self.store,job)
        self.assertIsNone(self.job())

    def test_cadence_and_lost_admission_survive_source_updates(self):
        self.sync(["第一句"]); job=self.job(); batch=prepare(self.store,job)
        self.assertIsNone(next_job(self.store, 1000, False))
        self.assertEqual(job["id"], next_job(self.store, 1000, True)["id"])
        self.store.db.execute("UPDATE jobs SET first_attempt=1000,replay_before=5000 WHERE id=?", (job["id"],))
        self.sync(["第一句", "新的句子"])
        retry=next_job(self.store, 1001, False)
        self.assertEqual(job["id"], retry["id"])
        self.assertEqual(batch,prepare(self.store,retry))
        self.store.db.execute("UPDATE jobs SET state='running' WHERE id=?", (job["id"],))
        self.assertEqual(job["id"],next_job(self.store,1061,False)["id"])
        finish(self.store, retry)
        self.assertIsNone(next_job(self.store, 1000 + AUTOMATIC_INTERVAL - 1, True))
        self.assertIsNotNone(next_job(self.store, 1000 + AUTOMATIC_INTERVAL, True))


if __name__ == "__main__": unittest.main()
