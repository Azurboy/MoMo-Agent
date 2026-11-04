#!/usr/bin/env python3
"""MoMo personal context & memory CLI for DeepSeek SuperAgent worker sessions.

Invoked via $DSH_SUPERAGENT_MOMO_CLI inside isolated SuperAgent tickets so
Hermes Agent and DeepSeek SuperAgent share the exact same ContextStore
(recordings, calendar, reminders, visits, health) and HermesMemory (MEMORY.md / USER.md).
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
from html import unescape
from html.parser import HTMLParser
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import sys
import time
from urllib.parse import parse_qs, quote_plus, unquote, urlparse
import urllib.request

REPOSITORY = Path(__file__).resolve().parents[3]
if str(REPOSITORY / "Apps/MacApp/Runtime") not in sys.path:
    sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Runtime"))
sys.path.insert(0, str(REPOSITORY / "Apps/MacApp/Context"))
sys.path.insert(0, str(REPOSITORY / "Vendor/HermesAgent"))

from superagent_runtime import classify_transcript_span


def _speaker_role(is_owner: bool | None) -> str:
    if is_owner is True:
        return "owner"
    if is_owner is False:
        return "other"
    return "unattributed"


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
            spk_label, spk_is_owner, _ = classify_transcript_span(span)
            if spk_label and "speaker" not in span:
                span["speaker"] = spk_label
            span["speaker_role"] = _speaker_role(spk_is_owner)
        if spans:
            result["recorded_start_local"] = spans[0].get("recorded_at_local")
            result["recorded_end_local"] = spans[-1].get("recorded_at_local")
        result["speaker_ownership_note"] = (
            "Only spans with speaker_role='owner' ([我]) are spoken by the user; "
            "spans with speaker_role='other' ([说话人 N] or other names) are spoken by other people."
        )
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
                    spk_label, spk_is_owner, _ = classify_transcript_span(span)
                    match_item = {
                        "source_id": row["id"],
                        "title": title,
                        "revision": row["revision"],
                        "seq": idx,
                        "span_id": span.get("id"),
                        "recorded_at": rec_at,
                        "recorded_at_local": _local_dt(rec_at),
                        "speaker_role": _speaker_role(spk_is_owner),
                        "text": text,
                    }
                    if spk_label:
                        match_item["speaker"] = spk_label
                    matches.append(match_item)
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


def _cmd_pim(data: Path, args: argparse.Namespace) -> dict:
    from apple_pim import ApplePIM

    payload = json.loads(args.args_json) if args.args_json else {}
    if not isinstance(payload, dict):
        raise ValueError("--args-json must decode to a JSON object")
    return ApplePIM(data).call_sync(args.op, payload)


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


class _ReadableHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._skip_depth = 0
        self._in_title = False
        self.title_parts: list[str] = []
        self.chunks: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lower = tag.lower()
        if lower in ("script", "style", "noscript", "svg", "template"):
            self._skip_depth += 1
        elif lower == "title":
            self._in_title = True
        elif self._skip_depth == 0 and lower in ("p", "div", "section", "article", "li", "h1", "h2", "h3", "h4", "br", "tr"):
            self.chunks.append("\n")

    def handle_endtag(self, tag: str) -> None:
        lower = tag.lower()
        if lower in ("script", "style", "noscript", "svg", "template") and self._skip_depth > 0:
            self._skip_depth -= 1
        elif lower == "title":
            self._in_title = False
        elif self._skip_depth == 0 and lower in ("p", "div", "section", "article", "li", "h1", "h2", "h3", "h4", "tr"):
            self.chunks.append("\n")

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title_parts.append(data)
        if self._skip_depth == 0:
            self.chunks.append(data)


def _is_public_http_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return False
    host = parsed.hostname.strip().lower()
    if host in ("localhost", "ip6-localhost") or host.endswith(".local"):
        return False
    try:
        infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)
    except OSError:
        return False
    if not infos:
        return False
    for info in infos:
        addr = info[4][0]
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            return False
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
            return False
    return True


def _stdlib_duckduckgo_search(query: str, limit: int) -> dict:
    url = f"https://html.duckduckgo.com/html/?q={quote_plus(query)}"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        html = resp.read(512_000).decode("utf-8", errors="replace")
    items: list[dict] = []
    pattern = re.compile(
        r'<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        re.IGNORECASE | re.DOTALL,
    )
    snippet_pattern = re.compile(
        r'<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>|<div[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</div>',
        re.IGNORECASE | re.DOTALL,
    )
    snippets = [
        unescape(re.sub(r"<[^>]+>", "", m.group(1) or m.group(2) or "")).strip()
        for m in snippet_pattern.finditer(html)
    ]
    for idx, match in enumerate(pattern.finditer(html)):
        raw_href, raw_title = match.group(1), match.group(2)
        href = unescape(raw_href).strip()
        if "uddg=" in href:
            qs = parse_qs(urlparse(href).query)
            if qs.get("uddg"):
                href = unquote(qs["uddg"][0])
        title = unescape(re.sub(r"<[^>]+>", "", raw_title)).strip()
        if not href.startswith(("http://", "https://")) or not title:
            continue
        items.append(
            {
                "position": len(items) + 1,
                "title": title,
                "url": href,
                "description": snippets[idx] if idx < len(snippets) else "",
            }
        )
        if len(items) >= limit:
            break
    return {"success": bool(items), "data": {"web": items}, **({} if items else {"error": "No web results returned"})}


def _stdlib_fetch_extract(urls: list[str], char_limit: int) -> dict:
    results: list[dict] = []
    for url in urls:
        clean_url = str(url or "").strip()
        if not _is_public_http_url(clean_url):
            results.append({"url": clean_url, "title": "", "content": "", "error": "Blocked or invalid URL"})
            continue
        try:
            req = urllib.request.Request(
                clean_url,
                headers={
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
                    "Accept": "text/html,application/xhtml+xml,text/plain,text/markdown;q=0.9,*/*;q=0.5",
                },
            )
            with urllib.request.urlopen(req, timeout=20) as resp:
                ctype = (resp.headers.get("Content-Type") or "").lower()
                raw = resp.read(1_500_000).decode("utf-8", errors="replace")
            if "html" in ctype or "<html" in raw[:1000].lower():
                parser = _ReadableHTMLParser()
                parser.feed(raw)
                title = " ".join("".join(parser.title_parts).split()).strip()
                lines = [" ".join(line.split()) for line in "".join(parser.chunks).splitlines()]
                content = "\n".join(line for line in lines if line).strip()
            else:
                title = ""
                content = raw.strip()
            if char_limit > 0 and len(content) > char_limit:
                content = content[:char_limit] + "\n...[truncated]"
            results.append({"url": clean_url, "title": title, "content": content, "error": None if content else "Empty page content"})
        except Exception as exc:
            results.append({"url": clean_url, "title": "", "content": "", "error": str(exc)})
    return {"results": results}


def _configure_hermes_env(data: Path) -> None:
    default_agent_hermes = Path.home() / "Library/Application Support/MoMoAgent/Agent/hermes"
    if (data / "hermes").is_dir() or not default_agent_hermes.is_dir():
        os.environ.setdefault("HERMES_HOME", str(data / "hermes"))
    else:
        os.environ.setdefault("HERMES_HOME", str(default_agent_hermes))


def _cmd_web_search(data: Path, args: argparse.Namespace) -> dict:
    limit = max(1, min(int(args.limit), 20))
    _configure_hermes_env(data)
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from tools import web_tools

            web_tools._ensure_web_plugins_loaded()
            orig_get = web_tools._get_search_backend
            backend = orig_get()
            # openai-native is a server-side Responses API tool and cannot execute standalone in CLI subprocesses.
            if backend == "openai-native":
                fallback_backend = (
                    web_tools._keyless_backend()
                    or ("ddgs" if web_tools._ddgs_package_importable() else None)
                )
                if fallback_backend:
                    web_tools._get_search_backend = lambda: fallback_backend
            try:
                raw_json = web_tools.web_search_tool(args.query, limit=limit)
            finally:
                web_tools._get_search_backend = orig_get
        parsed = json.loads(raw_json)
        if isinstance(parsed, dict) and parsed.get("success") and parsed.get("data", {}).get("web"):
            return parsed
    except Exception:
        parsed = None

    with contextlib.suppress(Exception):
        fallback = _stdlib_duckduckgo_search(args.query, limit)
        if fallback.get("success"):
            return fallback
    return parsed if isinstance(parsed, dict) else {"success": False, "error": "Web search unavailable"}


def _cmd_web_extract(data: Path, args: argparse.Namespace) -> dict:
    urls = [str(u).strip() for u in (args.urls or ()) if str(u).strip()][:8]
    char_limit = max(1000, min(int(args.char_limit), 60_000))
    _configure_hermes_env(data)
    parsed: dict | None = None
    try:
        with contextlib.redirect_stdout(sys.stderr):
            from agent.web_search_registry import get_provider as _wsp_get_provider
            from tools import web_tools

            web_tools._ensure_web_plugins_loaded()
            orig_get = web_tools._get_extract_backend
            pin = web_tools._configured_backend("extract_backend") or web_tools._configured_backend("backend")
            if not pin:
                cand = orig_get()
                prov = _wsp_get_provider(cand) if cand else None
                if prov is None or not prov.supports_extract():
                    keyless = web_tools._keyless_backend()
                    if keyless:
                        web_tools._get_extract_backend = lambda: keyless
            try:
                raw_json = asyncio.run(web_tools.web_extract_tool(urls, char_limit=char_limit))
            finally:
                web_tools._get_extract_backend = orig_get
        loaded = json.loads(raw_json)
        if isinstance(loaded, dict):
            parsed = loaded
            entries = loaded.get("results")
            if isinstance(entries, list) and entries and any(bool(e.get("content")) and not e.get("error") for e in entries if isinstance(e, dict)):
                return loaded
    except Exception:
        parsed = None

    with contextlib.suppress(Exception):
        fallback = _stdlib_fetch_extract(urls, char_limit)
        if any(bool(e.get("content")) for e in fallback.get("results", ())):
            return fallback
    return parsed if isinstance(parsed, dict) else {"success": False, "error": "Web extract unavailable"}


def main() -> int:
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

    wsearch = sub.add_parser("web-search", help="Search the public web via configured or keyless Hermes backends")
    wsearch.add_argument("query")
    wsearch.add_argument("--limit", type=int, default=5)

    wextract = sub.add_parser("web-extract", help="Extract clean readable text from public web URLs")
    wextract.add_argument("urls", nargs="+")
    wextract.add_argument("--char-limit", type=int, default=15000)

    pim_cmd = sub.add_parser("pim", help="Manage Apple Reminders, Calendar events, and Notes")
    pim_cmd.add_argument("op")
    pim_cmd.add_argument("--args-json", default="{}")

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
        "web-search": _cmd_web_search,
        "web-extract": _cmd_web_extract,
        "pim": _cmd_pim,
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
