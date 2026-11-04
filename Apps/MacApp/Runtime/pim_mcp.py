"""MoMo Agent MCP server for macOS Apple Reminders (待办), Calendar (日历), and Notes (备忘录)."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from apple_pim import ApplePIM

server = MCPServer("MoMo Agent PIM")


def _pim() -> ApplePIM:
    return ApplePIM(Path(os.environ["MOMO_AGENT_DIRECTORY"]))


async def _invoke(op: str, **kwargs) -> dict:
    try:
        return await _pim().call(op, kwargs)
    except Exception as exc:
        raise ToolError(str(exc)) from exc


# ── Reminders (待办 / 提醒事项) ───────────────────────────────────────────────


@server.tool()
async def list_reminder_lists() -> dict:
    """List Apple Reminders lists on the user's Mac (synced via iCloud with iPhone)."""
    return await _invoke("list_reminder_lists")


@server.tool()
async def search_reminders(
    query: str = "",
    status: Literal["incomplete", "completed", "all"] = "incomplete",
    list_name: str = "",
    list_id: str = "",
    limit: int = 30,
) -> dict:
    """Search todos in Apple Reminders. Always search before creating, editing, completing, or deleting a reminder to avoid duplicates and locate the exact reminder_id."""
    return await _invoke(
        "search_reminders",
        query=query,
        status=status,
        list_name=list_name or None,
        list_id=list_id or None,
        limit=limit,
    )


@server.tool()
async def read_reminder(reminder_id: str) -> dict:
    """Read full details of one Apple Reminder by reminder_id."""
    return await _invoke("read_reminder", reminder_id=reminder_id)


@server.tool()
async def create_reminder(
    title: str,
    due_at: str = "",
    notes: str = "",
    priority: int = 0,
    list_name: str = "",
    list_id: str = "",
    remind_at: str = "",
) -> dict:
    """Create a new todo in Apple Reminders. due_at accepts ISO-8601 datetime (e.g. '2026-11-05T10:00:00+08:00') or date-only ('2026-11-05'). priority: 0=none, 1=high, 5=medium, 9=low."""
    return await _invoke(
        "create_reminder",
        title=title,
        due_at=due_at or None,
        notes=notes or None,
        priority=priority,
        list_name=list_name or None,
        list_id=list_id or None,
        remind_at=remind_at or None,
    )


@server.tool()
async def update_reminder(
    reminder_id: str,
    title: str | None = None,
    due_at: str | None = None,
    notes: str | None = None,
    priority: int | None = None,
    list_name: str | None = None,
    list_id: str | None = None,
    completed: bool | None = None,
) -> dict:
    """Update an existing Apple Reminder's title, due_at (pass '' to clear due date), notes, priority, list, or completed state."""
    return await _invoke(
        "update_reminder",
        reminder_id=reminder_id,
        title=title,
        due_at=due_at,
        notes=notes,
        priority=priority,
        list_name=list_name,
        list_id=list_id,
        completed=completed,
    )


@server.tool()
async def complete_reminder(reminder_id: str, completed: bool = True) -> dict:
    """Mark an Apple Reminder as completed (completed=True) or reopen it (completed=False)."""
    return await _invoke("complete_reminder", reminder_id=reminder_id, completed=completed)


@server.tool()
async def delete_reminder(reminder_id: str) -> dict:
    """Delete an Apple Reminder by reminder_id."""
    return await _invoke("delete_reminder", reminder_id=reminder_id)


# ── Calendar (日历日程) ───────────────────────────────────────────────────────


@server.tool()
async def list_calendars() -> dict:
    """List Apple Calendar calendars and whether each allows modifications."""
    return await _invoke("list_calendars")


@server.tool()
async def search_calendar_events(
    start_at: str = "",
    end_at: str = "",
    query: str = "",
    calendar_name: str = "",
    calendar_id: str = "",
    limit: int = 30,
) -> dict:
    """Search Apple Calendar events within a date range (ISO-8601 start_at / end_at; defaults to -24h..+14d)."""
    return await _invoke(
        "search_calendar_events",
        start_at=start_at or None,
        end_at=end_at or None,
        query=query,
        calendar_name=calendar_name or None,
        calendar_id=calendar_id or None,
        limit=limit,
    )


@server.tool()
async def read_calendar_event(event_id: str) -> dict:
    """Read details of a specific Apple Calendar event by event_id."""
    return await _invoke("read_calendar_event", event_id=event_id)


@server.tool()
async def create_calendar_event(
    title: str,
    start_at: str,
    end_at: str = "",
    all_day: bool = False,
    location: str = "",
    notes: str = "",
    calendar_name: str = "",
    calendar_id: str = "",
    alert_minutes_before: int | None = None,
) -> dict:
    """Create a calendar event in Apple Calendar. start_at / end_at use ISO-8601 ('2026-11-05T14:00:00+08:00' or '2026-11-05' for all_day)."""
    return await _invoke(
        "create_calendar_event",
        title=title,
        start_at=start_at,
        end_at=end_at or None,
        all_day=all_day,
        location=location or None,
        notes=notes or None,
        calendar_name=calendar_name or None,
        calendar_id=calendar_id or None,
        alert_minutes_before=alert_minutes_before,
    )


@server.tool()
async def update_calendar_event(
    event_id: str,
    title: str | None = None,
    start_at: str | None = None,
    end_at: str | None = None,
    all_day: bool | None = None,
    location: str | None = None,
    notes: str | None = None,
    calendar_name: str | None = None,
    calendar_id: str | None = None,
) -> dict:
    """Update an existing Apple Calendar event by event_id."""
    return await _invoke(
        "update_calendar_event",
        event_id=event_id,
        title=title,
        start_at=start_at,
        end_at=end_at,
        all_day=all_day,
        location=location,
        notes=notes,
        calendar_name=calendar_name,
        calendar_id=calendar_id,
    )


@server.tool()
async def delete_calendar_event(event_id: str) -> dict:
    """Delete an Apple Calendar event by event_id."""
    return await _invoke("delete_calendar_event", event_id=event_id)


# ── Notes (备忘录) ────────────────────────────────────────────────────────────


@server.tool()
async def list_note_folders() -> dict:
    """List folders in Apple Notes."""
    return await _invoke("list_note_folders")


@server.tool()
async def search_notes(
    query: str = "",
    folder_name: str = "",
    folder_id: str = "",
    limit: int = 20,
) -> dict:
    """Search Apple Notes by title or body text."""
    return await _invoke(
        "search_notes",
        query=query,
        folder_name=folder_name or None,
        folder_id=folder_id or None,
        limit=limit,
    )


@server.tool()
async def read_note(note_id: str) -> dict:
    """Read the full plaintext content of an Apple Note by note_id."""
    return await _invoke("read_note", note_id=note_id)


@server.tool()
async def create_note(
    title: str,
    body: str = "",
    folder_name: str = "",
    folder_id: str = "",
) -> dict:
    """Create a new memo in Apple Notes."""
    return await _invoke(
        "create_note",
        title=title,
        body=body,
        folder_name=folder_name or None,
        folder_id=folder_id or None,
    )


@server.tool()
async def update_note(
    note_id: str,
    title: str | None = None,
    body: str | None = None,
    append: bool = False,
) -> dict:
    """Update an existing Apple Note (set append=True to append body lines instead of replacing)."""
    return await _invoke(
        "update_note",
        note_id=note_id,
        title=title,
        body=body,
        append=append,
    )


@server.tool()
async def delete_note(note_id: str) -> dict:
    """Delete an Apple Note by note_id."""
    return await _invoke("delete_note", note_id=note_id)


if __name__ == "__main__":
    server.run()
