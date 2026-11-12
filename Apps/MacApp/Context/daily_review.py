"""Freeze chat and transcript evidence for one paginated daily Dream."""
from contextlib import closing
import json
from pathlib import Path

from momo_memory import memory_home
from context_store import Conflict, canonical, digest
import memory_review as review
import transcript_ingestion as ingestion


def enqueue(store, data, now, manual=False):
    with store.write():
        active = store.db.execute("""
            SELECT * FROM memory_reviews WHERE kind='dream' AND state IN ('pending','running')
            AND (first_attempt IS NOT NULL OR json_extract(input,'$.daily')=1)
            ORDER BY rowid LIMIT 1
        """).fetchone()
        if active:
            if manual and active["first_attempt"] is None:
                store.db.execute("UPDATE memory_reviews SET input=json_set(input,'$.manual_requested_at',?) WHERE id=?",
                                 (now, active["id"]))
            return active, False

        # Old, unadmitted chat and Dream jobs are represented by their original
        # evidence below. Admitted runs are reconciled before dispatch gets here.
        store.db.execute("""UPDATE memory_reviews SET state='superseded' WHERE state='pending'
                            AND first_attempt IS NULL AND json_extract(input,'$.daily') IS NULL""")
        cursor = review.state(store, "chat_cursor", [0, 0])
        through = 0
        db_path = Path(data) / "runtime/conversation.sqlite"
        if db_path.is_file():
            with closing(review.readonly(db_path)) as db:
                through = db.execute("SELECT COALESCE(MAX(seq),0) FROM messages").fetchone()[0]
        # The old chat job never advanced its cursor on failure. Include those
        # messages in the new combined review before any subsequent messages.
        chat = review.chat_batch(store, data, cursor, through)
        jobs = store.db.execute("SELECT * FROM jobs WHERE state='pending' AND first_attempt IS NULL ORDER BY rowid").fetchall()
        stamp = review.signature(memory_home(Path(data)), cursor, store.revision)
        last = review.state(store, "dream", {})
        if not manual and not chat and not jobs:
            if last.get("signature") == stamp:
                return None, False
            if not last and cursor == [0, 0] and not store.db.execute("SELECT 1 FROM sources WHERE deleted=0").fetchone():
                return None, False

        payload = {"daily": True, "signature": stamp, "source_revision": store.revision,
                   "chat_cursor": cursor, "chat_through": through if chat else None,
                   "recording_queue": digest(canonical([j["id"] for j in jobs]))}
        if manual:
            payload["manual_requested_at"] = now
        job = review.enqueue(store, "dream", payload)
        if job["state"] != "pending":
            return None, False

        page = 0

        def append(job_id, batch):
            nonlocal page
            page += 1
            store.db.execute("INSERT INTO daily_review_pages(review_id,page,job_id,evidence) VALUES(?,?,?,?)",
                             (job["id"], page, job_id, canonical(batch)))

        while chat:
            append(None, chat)
            if not chat["remaining"]:
                break
            chat = review.chat_batch(store, data, chat["cursor"], through)
        for source_job in jobs:
            job_id = source_job["id"]
            for batch in ingestion.batches(store, source_job):
                if batch["passages"]:
                    append(job_id, batch)
                else:
                    store.db.execute("UPDATE jobs SET input=? WHERE id=?", (canonical(batch), job_id))
                    ingestion.finish_in_transaction(store, source_job, None)
                job_id = ingestion.next_page_job_id(job_id)
        return job, True


def read_page(store, review_id, page):
    if type(page) is not int or page < 1:
        raise ValueError("page must be a positive integer")
    with store.write():
        active = store.db.execute("SELECT 1 FROM memory_reviews WHERE id=? AND state IN ('pending','running') AND first_attempt IS NOT NULL",
                                  (review_id,)).fetchone()
        if not active:
            raise Conflict("Daily review is not active")
        total = store.db.execute("SELECT COUNT(*) FROM daily_review_pages WHERE review_id=?", (review_id,)).fetchone()[0]
        if not total and page == 1:
            return {"total_pages": 0, "next_page": None}
        row = store.db.execute("SELECT * FROM daily_review_pages WHERE review_id=? AND page=?", (review_id, page)).fetchone()
        if not row:
            raise ValueError("Page outside the daily review")
        if page > 1 and not store.db.execute("SELECT seen FROM daily_review_pages WHERE review_id=? AND page=?",
                                              (review_id, page - 1)).fetchone()[0]:
            raise ValueError("Read the preceding evidence page first")
        batch = json.loads(row["evidence"])
        if row["job_id"]:
            current = store.db.execute("SELECT revision,deleted FROM sources WHERE id=?", (batch["source_id"],)).fetchone()
            if not current or current["deleted"] or current["revision"] != batch["source_revision"]:
                batch = {"superseded": True}
        store.db.execute("UPDATE daily_review_pages SET seen=1 WHERE review_id=? AND page=?", (review_id, page))
        return {"page": page, "total_pages": total, "next_page": page + 1 if page < total else None, "evidence": batch}


def prompt(store, job):
    first = read_page(store, job["id"], 1)
    return (review.prompt(job) + "\n这是本次统一整理的聊天和录音。先处理第一页，再用 read_daily_evidence"
            " 带同一个 review_id 顺序读取 next_page，直到为空。在同一次 Dream 中整合所有证据和笔记。"
            "\nreview_id=" + job["id"] + "\nDAILY_EVIDENCE=" + canonical(first))


def finish_in_transaction(store, job, receipt):
    count, seen = store.db.execute("SELECT COUNT(*), COALESCE(SUM(seen),0) FROM daily_review_pages WHERE review_id=?",
                                   (job["id"],)).fetchone()
    if count and not seen:
        raise Conflict("Daily review has not received any evidence pages")
    receipt["pages_reviewed"], receipt["pages_remaining"] = seen, count - seen
    cursor = None
    for row in store.db.execute("SELECT * FROM daily_review_pages WHERE review_id=? AND seen=1 ORDER BY page", (job["id"],)):
        batch = json.loads(row["evidence"])
        if not row["job_id"]:
            cursor = batch["cursor"]
            continue
        source_job = store.db.execute("SELECT * FROM jobs WHERE id=? AND state='pending'", (row["job_id"],)).fetchone()
        source = store.db.execute("SELECT revision,deleted FROM sources WHERE id=?", (batch["source_id"],)).fetchone()
        if source_job and source and not source["deleted"] and source["revision"] == batch["source_revision"]:
            store.db.execute("UPDATE jobs SET input=? WHERE id=?", (row["evidence"], source_job["id"]))
            ingestion.finish_in_transaction(store, source_job, {"daily_review_id": job["id"], "page": row["page"]})
    if cursor is not None:
        review.set_state(store, "chat_cursor", cursor)
    store.db.execute("DELETE FROM daily_review_pages WHERE review_id=?", (job["id"],))
    return cursor
