#!/usr/bin/env python3
"""MoMo personal context & memory CLI for DeepSeek SuperAgent worker sessions.

Invoked via $DSH_SUPERAGENT_MOMO_CLI inside isolated SuperAgent tickets so
Hermes Agent and DeepSeek SuperAgent share the exact same ContextStore
(recordings, calendar, reminders, visits, health) and HermesMemory (MEMORY.md / USER.md).
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time

REPOSITORY = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Context"))
sys.path.insert(0, str(REPOSITORY / "Vendor/HermesAgent"))


def _local_dt(ts: float | int | None) -> str | None:
    if ts is None:
        return None
    try:
        val = float(ts)
    except (TypeError, ValueError):
        return None
    if val <= 0:
        return None
    return time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime(val))


def _open_context(data: Path):
    from context_store import ContextStore
    return ContextStore(data / "context")


def _cmd_recordings(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        result = store.list_sources(args.after, args.limit)
        items = result.get("items") or []
        for item in items:
            windows = item.pop("windows", None) or []
            item.pop("recorded_summary", None)
            if item.get("recorded_at") is None and windows:
                item["recorded_at"] = windows[0].get("recorded_at")
            if windows:
                item["ended_at"] = windows[-1].get("end_at")
            item["recorded_at_local"] = _local_dt(item.get("recorded_at"))
            item["ended_at_local"] = _local_dt(item.get("ended_at"))
        items.sort(key=lambda x: float(x.get("ended_at") or x.get("recorded_at") or 0.0), reverse=True)
        result["current_local_time"] = _local_dt(time.time())
        return result
    finally:
        store.close()


def _cmd_recording(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        result = store.read_source(args.source_id, args.revision or None, args.offset, args.limit)
        spans = result.get("spans") or []
        for span in spans:
            span["recorded_at_local"] = _local_dt(span.get("recorded_at"))
        if spans:
            result["recorded_start_local"] = spans[0].get("recorded_at_local")
            result["recorded_end_local"] = spans[-1].get("recorded_at_local")
        result["current_local_time"] = _local_dt(time.time())
        return result
    finally:
        store.close()


def _cmd_search(data: Path, args: argparse.Namespace) -> dict:
    query = args.query.strip().lower()
    store = _open_context(data)
    try:
        rows = store.db.execute(
            "SELECT id, revision, payload, updated FROM sources WHERE deleted = 0 ORDER BY updated DESC"
        ).fetchall()
        matches: list[dict] = []
        limit = max(1, min(args.limit, 50))
        now_local = _local_dt(time.time())
        for row in rows:
            payload = json.loads(row["payload"])
            title = payload.get("title") or row["id"]
            for idx, span in enumerate(payload.get("spans") or ()):
                text = str(span.get("text") or "")
                if query in text.lower():
                    rec_at = span.get("recorded_at")
                    matches.append(
                        {
                            "source_id": row["id"],
                            "title": title,
                            "revision": row["revision"],
                            "seq": idx,
                            "span_id": span.get("id"),
                            "recorded_at": rec_at,
                            "recorded_at_local": _local_dt(rec_at),
                            "text": text,
                        }
                    )
                    if len(matches) >= limit:
                        return {"query": args.query, "current_local_time": now_local, "matches": matches}
        return {"query": args.query, "current_local_time": now_local, "matches": matches}
    finally:
        store.close()


def _cmd_save_recording_result(data: Path, args: argparse.Namespace) -> dict:
    store = _open_context(data)
    try:
        return store.write_result(args.source_id, args.revision, args.title, args.text)
    finally:
        store.close()


def _cmd_phone_context(data: Path, args: argparse.Namespace) -> dict:
    from phone_sources import read_phone_sources
    store = _open_context(data)
    try:
        if args.kind == "all":
            return {
                kind: read_phone_sources(store, kind, "", args.limit)
                for kind in ("calendar", "reminders", "visits")
            }
        return read_phone_sources(store, args.kind, args.after, args.limit)
    finally:
        store.close()


def _cmd_health(data: Path, args: argparse.Namespace) -> dict:
    from health_store import read_health
    store = _open_context(data)
    try:
        return read_health(store, args.after, args.limit)
    finally:
        store.close()


def _cmd_memories(data: Path, args: argparse.Namespace) -> dict:
    from hermes_memory import HermesMemory
    return HermesMemory(data / "hermes").list(after=args.after, limit=args.limit)


def _cmd_remember(data: Path, args: argparse.Namespace) -> dict:
    from hermes_memory import HermesMemory
    memory = HermesMemory(data / "hermes")
    with memory.store() as store:
        result = store.add(args.target, args.text.strip())
    return result


def _cmd_forget(data: Path, args: argparse.Namespace) -> dict:
    from hermes_memory import HermesMemory
    return HermesMemory(data / "hermes").forget(args.memory_id)


def _cmd_conversation(data: Path, args: argparse.Namespace) -> dict:
    import sqlite3
    db_path = data / "runtime/conversation.sqlite"
    if not db_path.is_file():
        return {"current_local_time": _local_dt(time.time()), "messages": []}
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT seq, id, role, content, created_at, run_id FROM messages ORDER BY seq DESC LIMIT ?",
            (max(1, min(args.limit, 50)),),
        ).fetchall()
        messages = []
        for row in reversed(rows):
            item = dict(row)
            item["created_at_local"] = _local_dt(item.get("created_at"))
            messages.append(item)
        return {"current_local_time": _local_dt(time.time()), "messages": messages}
    finally:
        conn.close()


def main() -> int:
    import os
    default_data = Path(os.environ["MOMO_DATA_DIR"]) if os.environ.get("MOMO_DATA_DIR") else None
    parser = argparse.ArgumentParser(description="MoMo personal context & memory CLI")
    parser.add_argument("--data-dir", type=Path, default=default_data, required=default_data is None)
    sub = parser.add_subparsers(dest="command", required=True)

    rec_list = sub.add_parser("recordings", help="List synchronized voice recordings")
    rec_list.add_argument("--after", default="")
    rec_list.add_argument("--limit", type=int, default=25)

    rec_read = sub.add_parser("recording", help="Read full voice transcript with citations")
    rec_read.add_argument("source_id")
    rec_read.add_argument("--revision", default="")
    rec_read.add_argument("--offset", type=int, default=0)
    rec_read.add_argument("--limit", type=int, default=12000)

    rec_search = sub.add_parser("search", help="Search voice recording transcripts")
    rec_search.add_argument("query")
    rec_search.add_argument("--limit", type=int, default=20)

    rec_save = sub.add_parser("save-result", help="Save a Markdown note attached to a recording")
    rec_save.add_argument("source_id")
    rec_save.add_argument("--revision", required=True)
    rec_save.add_argument("--title", required=True)
    rec_save.add_argument("--text", required=True)

    phone = sub.add_parser("phone-context", help="Read calendar, reminders, or visits snapshots")
    phone.add_argument("--kind", choices=("calendar", "reminders", "visits", "all"), default="all")
    phone.add_argument("--after", default="")
    phone.add_argument("--limit", type=int, default=30)

    health = sub.add_parser("health", help="Read HealthKit step and heart-rate snapshots")
    health.add_argument("--after", default="")
    health.add_argument("--limit", type=int, default=20)

    mem_list = sub.add_parser("memories", help="List shared MoMo memories and user profile facts")
    mem_list.add_argument("--after", default="")
    mem_list.add_argument("--limit", type=int, default=100)

    mem_add = sub.add_parser("remember", help="Add an entry to shared MEMORY.md or USER.md")
    mem_add.add_argument("--target", choices=("memory", "user"), default="memory")
    mem_add.add_argument("text")

    mem_del = sub.add_parser("forget", help="Delete a shared memory entry by id")
    mem_del.add_argument("memory_id")

    conv = sub.add_parser("conversation", help="Read recent MoMo chat history")
    conv.add_argument("--limit", type=int, default=20)

    args = parser.parse_args()
    data = args.data_dir.expanduser().resolve()
    handlers = {
        "recordings": _cmd_recordings,
        "recording": _cmd_recording,
        "search": _cmd_search,
        "save-result": _cmd_save_recording_result,
        "phone-context": _cmd_phone_context,
        "health": _cmd_health,
        "memories": _cmd_memories,
        "remember": _cmd_remember,
        "forget": _cmd_forget,
        "conversation": _cmd_conversation,
    }
    try:
        output = handlers[args.command](data, args)
        print(json.dumps(output, ensure_ascii=False, indent=2))
        return 0
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
