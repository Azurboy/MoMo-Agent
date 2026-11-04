"""Shared macOS Apple Reminders, Calendar, and Notes service for MoMo Agent (MCP, CLI, and SuperAgent)."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Callable, Awaitable
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Access"))
from desktop_control import native_request, socket_path

PIM_OPS = frozenset(
    {
        # Reminders (待办)
        "list_reminder_lists",
        "search_reminders",
        "read_reminder",
        "create_reminder",
        "update_reminder",
        "complete_reminder",
        "delete_reminder",
        # Calendar (日历)
        "list_calendars",
        "search_calendar_events",
        "read_calendar_event",
        "create_calendar_event",
        "update_calendar_event",
        "delete_calendar_event",
        # Notes (备忘录)
        "list_note_folders",
        "search_notes",
        "read_note",
        "create_note",
        "update_note",
        "delete_note",
    }
)

PIM_WRITE_OPS: dict[str, str] = {
    "create_reminder": "reminder",
    "update_reminder": "reminder",
    "complete_reminder": "reminder",
    "delete_reminder": "reminder",
    "create_calendar_event": "event",
    "update_calendar_event": "event",
    "delete_calendar_event": "event",
    "create_note": "note",
    "update_note": "note",
    "delete_note": "note",
}

_FALLBACK_JXA_SCRIPT = r"""
ObjC.import('Foundation');
function escHtml(s) {
  return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function toNoteHtml(title, body) {
  const t = escHtml(title);
  const raw = String(body || '');
  const hasHtml = /<(?:div|p|ul|ol|li|h[1-6]|br|b|i|strong|em)\b/i.test(raw);
  const rendered = hasHtml ? raw : raw.split(/\r?\n/).map(line => line.trim() ? '<div>' + escHtml(line) + '</div>' : '<div><br></div>').join('');
  return '<div><h1>' + t + '</h1></div>' + (rendered ? rendered : '');
}
function iso(d) { try { return d ? new Date(d.getTime()).toISOString() : null; } catch (e) { return null; } }
function parseDate(raw) {
  if (!raw) return null;
  const s = String(raw).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return new Date(s + 'T09:00:00');
  const d = new Date(s);
  return isFinite(d.getTime()) ? d : null;
}
function run() {
  const env = $.NSProcessInfo.processInfo.environment;
  const raw = ObjC.unwrap(env.objectForKey('MOMO_PIM_JXA_PAYLOAD'));
  const req = JSON.parse(raw);
  const op = req.op, args = req.args || {};

  if (op.includes('note')) {
    const Notes = Application('Notes');
    if (op === 'list_note_folders') {
      const folders = [];
      for (const acc of Notes.accounts()) {
        const accName = String(acc.name() || '');
        for (const f of acc.folders()) {
          const fname = String(f.name() || '');
          if (fname === 'Recently Deleted' || fname === '最近删除') continue;
          folders.push({ id: String(f.id()), name: fname, account: accName });
        }
      }
      return JSON.stringify({ ok: true, folders });
    }
    function findFolder(fid, fname) {
      for (const acc of Notes.accounts()) {
        for (const f of acc.folders()) {
          if (fid && String(f.id()) === fid) return f;
          if (fname && String(f.name()).toLowerCase() === String(fname).toLowerCase()) return f;
        }
      }
      return Notes.defaultAccount().defaultFolder();
    }
    function serNote(n, full) {
      const o = { id: String(n.id()), title: String(n.name() || ''), created_at: iso(n.creationDate()), updated_at: iso(n.modificationDate()) };
      try { o.folder = String(n.container().name() || ''); } catch (e) { o.folder = ''; }
      const p = String(n.plaintext() || '');
      if (full) o.body_text = p;
      o.preview = p.slice(0, 220);
      return o;
    }
    if (op === 'search_notes') {
      const q = String(args.query || '').trim().toLowerCase();
      const lim = Math.min(50, Math.max(1, Number(args.limit || 20)));
      const cont = (args.folder_id || args.folder_name) ? findFolder(args.folder_id, args.folder_name) : Notes;
      const all = cont.notes();
      const items = [];
      for (let i = 0; i < all.length && items.length < lim; i++) {
        const n = all[i];
        let fn = '';
        try { fn = String(n.container().name() || ''); } catch (e) {}
        if (fn === 'Recently Deleted' || fn === '最近删除') continue;
        const name = String(n.name() || '');
        const plain = q ? String(n.plaintext() || '') : '';
        if (q && !name.toLowerCase().includes(q) && !plain.toLowerCase().includes(q)) continue;
        items.push(serNote(n, false));
      }
      return JSON.stringify({ ok: true, items, count: items.length });
    }
    const matches = args.note_id ? Notes.notes.whose({ id: String(args.note_id) })() : [];
    const target = matches && matches.length ? matches[0] : null;
    if (op === 'read_note') {
      if (!target) return JSON.stringify({ ok: false, error: '未找到指定的备忘录。' });
      return JSON.stringify({ ok: true, item: serNote(target, true) });
    }
    if (op === 'create_note') {
      const title = String(args.title || '').trim();
      if (!title) return JSON.stringify({ ok: false, state: 'needs_clarification', error: '备忘录标题不能为空。' });
      const folder = findFolder(args.folder_id, args.folder_name);
      const note = Notes.Note({ body: toNoteHtml(title, args.body || '') });
      folder.notes.push(note);
      return JSON.stringify({ ok: true, state: 'succeeded', item: serNote(note, true) });
    }
    if (op === 'update_note') {
      if (!target) return JSON.stringify({ ok: false, state: 'failed', error: '未找到要修改的备忘录。' });
      const title = String(args.title || target.name() || '').trim() || '备忘录';
      if (args.append) {
        const extra = String(args.body || '').split(/\r?\n/).map(line => line.trim() ? '<div>' + escHtml(line) + '</div>' : '<div><br></div>').join('');
        target.body = String(target.body() || '') + '<div><br></div>' + extra;
      } else {
        target.body = toNoteHtml(title, args.body !== undefined ? args.body : target.plaintext());
      }
      return JSON.stringify({ ok: true, state: 'succeeded', item: serNote(target, true) });
    }
    if (op === 'delete_note') {
      if (!target) return JSON.stringify({ ok: false, state: 'failed', error: '未找到要删除的备忘录。' });
      const item = serNote(target, false);
      Notes.delete(target);
      return JSON.stringify({ ok: true, state: 'succeeded', item });
    }
  }

  if (op.includes('reminder')) {
    const Rem = Application('Reminders');
    function serRem(r, listName) {
      const o = { id: String(r.id()), title: String(r.name() || ''), list_name: listName || '', completed: Boolean(r.completed()), priority: Number(r.priority() || 0), notes: String(r.body() || '') };
      const due = iso(r.dueDate());
      if (due) o.due_at = due;
      return o;
    }
    if (op === 'list_reminder_lists') {
      const defId = String(Rem.defaultList().id());
      const lists = Rem.lists().map(l => ({ id: String(l.id()), title: String(l.name()), allows_modifications: true, is_default: String(l.id()) === defId }));
      return JSON.stringify({ ok: true, lists });
    }
    function targetList() {
      for (const l of Rem.lists()) {
        if (args.list_id && String(l.id()) === String(args.list_id)) return l;
        if (args.list_name && String(l.name()).toLowerCase() === String(args.list_name).toLowerCase()) return l;
      }
      return Rem.defaultList();
    }
    if (op === 'search_reminders') {
      const lists = (args.list_id || args.list_name) ? [targetList()] : Rem.lists();
      const status = String(args.status || 'incomplete').toLowerCase();
      const q = String(args.query || '').trim().toLowerCase();
      const lim = Math.min(100, Math.max(1, Number(args.limit || 30)));
      const items = [];
      for (const l of lists) {
        const lname = String(l.name());
        const subset = status === 'completed' ? l.reminders.whose({ completed: true })() : status === 'all' ? l.reminders() : l.reminders.whose({ completed: false })();
        for (let i = 0; i < subset.length && items.length < lim; i++) {
          const r = subset[i];
          const t = String(r.name() || ''), b = q ? String(r.body() || '') : '';
          if (q && !t.toLowerCase().includes(q) && !b.toLowerCase().includes(q)) continue;
          items.push(serRem(r, lname));
        }
        if (items.length >= lim) break;
      }
      return JSON.stringify({ ok: true, items, count: items.length });
    }
    if (op === 'create_reminder') {
      const title = String(args.title || '').trim();
      if (!title) return JSON.stringify({ ok: false, state: 'needs_clarification', error: '待办标题不能为空。' });
      const l = targetList();
      const props = { name: title };
      if (args.notes) props.body = String(args.notes);
      if (args.priority !== undefined) props.priority = Number(args.priority);
      const due = parseDate(args.due_at);
      if (due) props.dueDate = due;
      const r = Rem.Reminder(props);
      l.reminders.push(r);
      return JSON.stringify({ ok: true, state: 'succeeded', item: serRem(r, String(l.name())) });
    }
    const rMatches = args.reminder_id ? Rem.reminders.whose({ id: String(args.reminder_id) })() : [];
    const rTarget = rMatches && rMatches.length ? rMatches[0] : null;
    if (op === 'read_reminder') {
      if (!rTarget) return JSON.stringify({ ok: false, error: '未找到指定的待办事项。' });
      return JSON.stringify({ ok: true, item: serRem(rTarget, '') });
    }
    if (op === 'update_reminder') {
      if (!rTarget) return JSON.stringify({ ok: false, state: 'failed', error: '未找到要修改的待办事项。' });
      if (args.title) rTarget.name = String(args.title).trim();
      if (args.notes !== undefined) rTarget.body = String(args.notes);
      if (args.priority !== undefined) rTarget.priority = Number(args.priority);
      if (args.due_at !== undefined) rTarget.dueDate = String(args.due_at).trim() ? parseDate(args.due_at) : null;
      if (args.completed !== undefined) rTarget.completed = Boolean(args.completed);
      return JSON.stringify({ ok: true, state: 'succeeded', item: serRem(rTarget, '') });
    }
    if (op === 'complete_reminder') {
      if (!rTarget) return JSON.stringify({ ok: false, state: 'failed', error: '未找到要更新完成状态的待办事项。' });
      rTarget.completed = args.completed !== undefined ? Boolean(args.completed) : true;
      return JSON.stringify({ ok: true, state: 'succeeded', item: serRem(rTarget, '') });
    }
    if (op === 'delete_reminder') {
      if (!rTarget) return JSON.stringify({ ok: false, state: 'failed', error: '未找到要删除的待办事项。' });
      const item = serRem(rTarget, '');
      Rem.delete(rTarget);
      return JSON.stringify({ ok: true, state: 'succeeded', item });
    }
  }

  const Cal = Application('Calendar');
  if (op === 'list_calendars') {
    const calendars = Cal.calendars().map(c => ({ id: String(c.id()), title: String(c.name()), allows_modifications: Boolean(c.writable()) }));
    return JSON.stringify({ ok: true, calendars });
  }
  return JSON.stringify({ ok: false, error: '请保持 Mac 上的 MoMo Agent 打开以使用完整日历日程服务。' });
}
"""


def _wrap_receipt(op: str, raw: dict[str, Any]) -> dict[str, Any]:
    kind = PIM_WRITE_OPS.get(op)
    if not kind:
        return raw
    if "actionID" in raw and "state" in raw:
        return raw
    action_id = str(uuid.uuid4())
    if raw.get("ok") is False:
        return {
            "ok": False,
            "actionID": action_id,
            "state": raw.get("state") or "failed",
            "error": raw.get("error") or "操作未完成。",
            "resource": {"kind": kind, "fields": {}},
        }
    item = raw.get("item") if isinstance(raw.get("item"), dict) else {}
    fields: dict[str, Any] = {"title": str(item.get("title") or "")}
    if kind == "reminder":
        fields["completed"] = bool(item.get("completed", False))
        if item.get("due_at"):
            fields["dueAt"] = item["due_at"]
        if item.get("list_name"):
            fields["list"] = item["list_name"]
    elif kind == "event":
        if item.get("start_at"):
            fields["start"] = item["start_at"]
        if item.get("end_at"):
            fields["end"] = item["end_at"]
        if item.get("calendar_name"):
            fields["calendar"] = item["calendar_name"]
    elif kind == "note":
        if item.get("folder"):
            fields["folder"] = item["folder"]
    return {
        "ok": True,
        "actionID": action_id,
        "state": "succeeded",
        "resource": {"kind": kind, "id": str(item.get("id") or ""), "fields": fields},
        "item": item,
    }


class ApplePIM:
    """Unified PIM gateway using MoMo Agent.app's native EventKit/Notes driver with JXA CLI fallback."""

    def __init__(
        self,
        data: Path,
        *,
        transport: Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]] | dict[str, Any]] | None = None,
    ) -> None:
        self.data = Path(data)
        self._transport = transport

    async def call(self, op: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
        if op not in PIM_OPS:
            raise ValueError(f"Unsupported PIM operation: {op}")
        clean_args = {k: v for k, v in (args or {}).items() if v is not None}

        if self._transport is not None:
            res = self._transport(op, clean_args)
            if asyncio.iscoroutine(res):
                res = await res
            return _wrap_receipt(op, dict(res))

        sock = Path(socket_path(self.data))
        if sock.exists() and (self.data / "api-key").is_file():
            try:
                result = await native_request(
                    self.data,
                    {"op": "pim", "actor": "agent", "pim_op": op, "args": clean_args},
                )
                if "error" in result and "actionID" not in result:
                    if op in PIM_WRITE_OPS:
                        return _wrap_receipt(op, {"ok": False, "state": "failed", "error": result["error"]})
                    raise RuntimeError(str(result["error"]))
                return _wrap_receipt(op, result)
            except (OSError, asyncio.TimeoutError):
                pass

        raw = await asyncio.to_thread(self._run_fallback_jxa, op, clean_args)
        return _wrap_receipt(op, raw)

    def call_sync(self, op: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
        return asyncio.run(self.call(op, args))

    @staticmethod
    def _run_fallback_jxa(op: str, args: dict[str, Any]) -> dict[str, Any]:
        env = dict(os.environ)
        env["MOMO_PIM_JXA_PAYLOAD"] = json.dumps({"op": op, "args": args}, ensure_ascii=False)
        proc = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", _FALLBACK_JXA_SCRIPT],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if proc.returncode != 0:
            err = (proc.stderr or "").strip()
            if "-1743" in err or "not authorized" in err.lower():
                return {
                    "ok": False,
                    "state": "needs_permission",
                    "error": "请在 Mac「系统设置 -> 隐私与安全性」中允许访问提醒事项 / 日历 / 备忘录。",
                }
            raise RuntimeError(err or f"osascript exited with code {proc.returncode}")
        parsed = json.loads(proc.stdout or "{}")
        if parsed.get("ok") is False and op not in PIM_WRITE_OPS:
            raise RuntimeError(str(parsed.get("error") or "PIM query failed"))
        return parsed
