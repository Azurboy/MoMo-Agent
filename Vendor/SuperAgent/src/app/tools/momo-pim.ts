/** Built-in MoMo PIM tools for Apple Reminders (待办), Calendar (日历), and Notes (备忘录) on the user's Mac. */
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { z } from 'zod'
import { liveTicket, runningAssignment } from '../../core/index.ts'
import type { ExecutorToolsHost } from './executor.ts'
import type { Tool } from './tool.ts'

export function momoPimTools(host: ExecutorToolsHost, ticketId: string): Tool[] {
  const bridge = process.env.MOMO_COMPUTER_BRIDGE, data = process.env.MOMO_DATA_DIR
  if (!bridge || !data) return []
  const url = new URL(bridge)
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1') throw new Error('MoMo PIM bridge must be loopback')
  const call = async (op: string, args: unknown, signal: AbortSignal) => {
    const secret = JSON.parse(await readFile(join(data, 'superagent/state/momo-bridge.json'), 'utf8')) as { secret: string }
    signal.throwIfAborted()
    const current = host.store.tickets.get(ticketId)
    const assignment = current && runningAssignment(current)
    if (!current || !liveTicket(current) || current.attention || !assignment) throw new Error('Ticket is not running')
    const response = await fetch(new URL('/momo/internal/superagent/pim', url), {
      method: 'POST',
      signal: AbortSignal.any([signal, AbortSignal.timeout(25000)]),
      headers: { 'content-type': 'application/json', 'x-momo-bridge': secret.secret },
      body: JSON.stringify({ ticket_id: ticketId, assignment_id: assignment.id, op, args }),
    })
    const result = await response.json() as { error?: string }
    if (!response.ok) throw new Error(result.error ?? `PIM bridge returned ${response.status}`)
    return result
  }

  return [
    // ── Reminders (待办 / 提醒事项) ────────────────────────────────────────────
    {
      name: 'list_reminder_lists',
      description: 'List Apple Reminders lists on the Mac (synced via iCloud with iPhone).',
      schema: z.object({}).strict(),
      execute: (args, signal) => call('list_reminder_lists', args, signal),
    },
    {
      name: 'search_reminders',
      description: 'Search todos in Apple Reminders. Always search before creating, updating, completing, or deleting a reminder to avoid duplicates and find exact reminder_id.',
      schema: z.object({
        query: z.string().max(300).default(''),
        status: z.enum(['incomplete', 'completed', 'all']).default('incomplete'),
        list_name: z.string().max(200).default(''),
        list_id: z.string().max(200).default(''),
        limit: z.number().int().min(1).max(100).default(30),
      }).strict(),
      execute: (args, signal) => call('search_reminders', args, signal),
    },
    {
      name: 'read_reminder',
      description: 'Read full details of one Apple Reminder by reminder_id.',
      schema: z.object({ reminder_id: z.string().min(1).max(300) }).strict(),
      execute: (args, signal) => call('read_reminder', args, signal),
    },
    {
      name: 'create_reminder',
      description: 'Create a todo in Apple Reminders. due_at accepts ISO-8601 datetime (e.g. "2026-11-05T10:00:00+08:00") or date-only ("2026-11-05"). priority: 0=none, 1=high, 5=medium, 9=low.',
      schema: z.object({
        title: z.string().trim().min(1).max(500),
        due_at: z.string().max(64).default(''),
        notes: z.string().max(4000).default(''),
        priority: z.number().int().min(0).max(9).default(0),
        list_name: z.string().max(200).default(''),
        list_id: z.string().max(200).default(''),
        remind_at: z.string().max(64).default(''),
      }).strict(),
      execute: (args, signal) => call('create_reminder', args, signal),
    },
    {
      name: 'update_reminder',
      description: 'Update an existing Apple Reminder (title, due_at — pass "" to clear due date, notes, priority, list, or completed).',
      schema: z.object({
        reminder_id: z.string().min(1).max(300),
        title: z.string().trim().min(1).max(500).optional(),
        due_at: z.string().max(64).optional(),
        notes: z.string().max(4000).optional(),
        priority: z.number().int().min(0).max(9).optional(),
        list_name: z.string().max(200).optional(),
        list_id: z.string().max(200).optional(),
        completed: z.boolean().optional(),
      }).strict(),
      execute: (args, signal) => call('update_reminder', args, signal),
    },
    {
      name: 'complete_reminder',
      description: 'Mark an Apple Reminder completed (completed=true) or reopen it (completed=false).',
      schema: z.object({
        reminder_id: z.string().min(1).max(300),
        completed: z.boolean().default(true),
      }).strict(),
      execute: (args, signal) => call('complete_reminder', args, signal),
    },
    {
      name: 'delete_reminder',
      description: 'Delete an Apple Reminder by reminder_id.',
      schema: z.object({ reminder_id: z.string().min(1).max(300) }).strict(),
      execute: (args, signal) => call('delete_reminder', args, signal),
    },

    // ── Calendar (日历日程) ────────────────────────────────────────────────────
    {
      name: 'list_calendars',
      description: 'List Apple Calendar calendars and whether each allows modifications.',
      schema: z.object({}).strict(),
      execute: (args, signal) => call('list_calendars', args, signal),
    },
    {
      name: 'search_calendar_events',
      description: 'Search Apple Calendar events within a date range (ISO-8601 start_at / end_at; defaults to -24h..+14d).',
      schema: z.object({
        start_at: z.string().max(64).default(''),
        end_at: z.string().max(64).default(''),
        query: z.string().max(300).default(''),
        calendar_name: z.string().max(200).default(''),
        calendar_id: z.string().max(200).default(''),
        limit: z.number().int().min(1).max(100).default(30),
      }).strict(),
      execute: (args, signal) => call('search_calendar_events', args, signal),
    },
    {
      name: 'read_calendar_event',
      description: 'Read details of one Apple Calendar event by event_id.',
      schema: z.object({ event_id: z.string().min(1).max(300) }).strict(),
      execute: (args, signal) => call('read_calendar_event', args, signal),
    },
    {
      name: 'create_calendar_event',
      description: 'Create an event in Apple Calendar. start_at / end_at use ISO-8601 ("2026-11-05T14:00:00+08:00" or "2026-11-05" for all_day).',
      schema: z.object({
        title: z.string().trim().min(1).max(500),
        start_at: z.string().min(1).max(64),
        end_at: z.string().max(64).default(''),
        all_day: z.boolean().default(false),
        location: z.string().max(500).default(''),
        notes: z.string().max(4000).default(''),
        calendar_name: z.string().max(200).default(''),
        calendar_id: z.string().max(200).default(''),
        alert_minutes_before: z.number().int().min(0).max(10080).optional(),
      }).strict(),
      execute: (args, signal) => call('create_calendar_event', args, signal),
    },
    {
      name: 'update_calendar_event',
      description: 'Update an existing Apple Calendar event by event_id.',
      schema: z.object({
        event_id: z.string().min(1).max(300),
        title: z.string().trim().min(1).max(500).optional(),
        start_at: z.string().max(64).optional(),
        end_at: z.string().max(64).optional(),
        all_day: z.boolean().optional(),
        location: z.string().max(500).optional(),
        notes: z.string().max(4000).optional(),
        calendar_name: z.string().max(200).optional(),
        calendar_id: z.string().max(200).optional(),
      }).strict(),
      execute: (args, signal) => call('update_calendar_event', args, signal),
    },
    {
      name: 'delete_calendar_event',
      description: 'Delete an Apple Calendar event by event_id.',
      schema: z.object({ event_id: z.string().min(1).max(300) }).strict(),
      execute: (args, signal) => call('delete_calendar_event', args, signal),
    },

    // ── Notes (备忘录) ─────────────────────────────────────────────────────────
    {
      name: 'list_note_folders',
      description: 'List folders in Apple Notes.',
      schema: z.object({}).strict(),
      execute: (args, signal) => call('list_note_folders', args, signal),
    },
    {
      name: 'search_notes',
      description: 'Search Apple Notes by title or body text.',
      schema: z.object({
        query: z.string().max(300).default(''),
        folder_name: z.string().max(200).default(''),
        folder_id: z.string().max(200).default(''),
        limit: z.number().int().min(1).max(50).default(20),
      }).strict(),
      execute: (args, signal) => call('search_notes', args, signal),
    },
    {
      name: 'read_note',
      description: 'Read full plaintext content of an Apple Note by note_id.',
      schema: z.object({ note_id: z.string().min(1).max(500) }).strict(),
      execute: (args, signal) => call('read_note', args, signal),
    },
    {
      name: 'create_note',
      description: 'Create a memo in Apple Notes.',
      schema: z.object({
        title: z.string().trim().min(1).max(500),
        body: z.string().max(20000).default(''),
        folder_name: z.string().max(200).default(''),
        folder_id: z.string().max(200).default(''),
      }).strict(),
      execute: (args, signal) => call('create_note', args, signal),
    },
    {
      name: 'update_note',
      description: 'Update an existing Apple Note (set append=true to append body lines instead of replacing).',
      schema: z.object({
        note_id: z.string().min(1).max(500),
        title: z.string().trim().min(1).max(500).optional(),
        body: z.string().max(20000).optional(),
        append: z.boolean().default(false),
      }).strict(),
      execute: (args, signal) => call('update_note', args, signal),
    },
    {
      name: 'delete_note',
      description: 'Delete an Apple Note by note_id.',
      schema: z.object({ note_id: z.string().min(1).max(500) }).strict(),
      execute: (args, signal) => call('delete_note', args, signal),
    },

    // ── Dream Markdown Notebook, Core Memory & Semantic Speaker Relabeling ──────
    {
      name: 'list_memory_notebooks',
      description: 'List pure Markdown (.md) living notebook pages across the multi-level memories/ vault (optionally filtered by category or folder path prefix).',
      schema: z.object({
        category: z.string().max(180).optional(),
        path: z.string().max(240).optional(),
      }).strict(),
      execute: (args, signal) => call('list_memory_notebooks', args, signal),
    },
    {
      name: 'read_memory_notebook',
      description: 'Read a pure Markdown (.md) living notebook page or core memory file by relative multi-level `path` (e.g. "projects/AI访谈/双月OKR.md", "BRIEFING.md", "MEMORY.md") or `(category, slug)`.',
      schema: z.object({
        path: z.string().max(240).optional(),
        category: z.string().max(180).optional(),
        slug: z.string().max(180).optional(),
      }).strict(),
      execute: (args, signal) => call('read_memory_notebook', args, signal),
    },
    {
      name: 'write_memory_notebook',
      description: 'Create or update a pure Markdown (.md) living notebook page anywhere in the multi-level memories/ vault. Prefer passing `path` directly with 2nd/3rd-level folders as needed (e.g. "projects/AI访谈/双月OKR.md", "journal/2026-11/2026-11-10.md", "people/核心团队/小林.md", or custom folders). Content must be clean user-facing Markdown.',
      schema: z.object({
        path: z.string().max(240).optional(),
        category: z.string().max(180).optional(),
        slug: z.string().max(180).optional(),
        title: z.string().max(200).optional(),
        content: z.string().min(1).max(32000),
        mode: z.enum(['replace', 'append']).default('replace'),
      }).strict(),
      execute: (args, signal) => call('write_memory_notebook', args, signal),
    },
    {
      name: 'move_memory_notebook',
      description: 'Move or rename a Markdown notebook page to reorganize the memories/ vault into multi-level directories (automatically prunes empty folders).',
      schema: z.object({
        from_path: z.string().min(1).max(240),
        to_path: z.string().min(1).max(240),
        overwrite: z.boolean().default(false),
      }).strict(),
      execute: (args, signal) => call('move_memory_notebook', args, signal),
    },
    {
      name: 'remove_memory_notebook',
      description: 'Remove an obsolete or merged Markdown notebook page by `path` or `(category, slug)`.',
      schema: z.object({
        path: z.string().max(240).optional(),
        category: z.string().max(180).optional(),
        slug: z.string().max(180).optional(),
      }).strict(),
      execute: (args, signal) => call('remove_memory_notebook', args, signal),
    },
    {
      name: 'update_core_memory',
      description: 'Add, patch, or remove concise entries in core MEMORY.md (target="memory") or USER.md (target="user").',
      schema: z.object({
        action: z.enum(['add', 'patch', 'remove']),
        target: z.enum(['memory', 'user']).default('memory'),
        content: z.string().max(4000).optional(),
        old_text: z.string().max(2000).optional(),
      }).strict(),
      execute: (args, signal) => call('update_core_memory', args, signal),
    },
    {
      name: 'list_recordings',
      description: 'List synchronized phone recordings with source_id, source_revision, local timestamps, and previews.',
      schema: z.object({
        after: z.string().max(200).default(''),
        limit: z.number().int().min(1).max(50).default(20),
      }).strict(),
      execute: (args, signal) => call('list_recordings', args, signal),
    },
    {
      name: 'search_recordings',
      description: 'Full-text search across synchronized recordings to locate exact source_id, span_id, timestamps, and current speaker labels for any topic, quote, or OKR.',
      schema: z.object({
        query: z.string().trim().min(1).max(300),
        limit: z.number().int().min(1).max(30).default(15),
      }).strict(),
      execute: (args, signal) => call('search_recordings', args, signal),
    },
    {
      name: 'read_recording',
      description: 'Read original transcript spans (with span id, speaker, speaker_role, recorded_at_local) by source_id and offset.',
      schema: z.object({
        source_id: z.string().min(1).max(200),
        source_revision: z.string().max(200).default(''),
        offset: z.number().int().min(0).default(0),
        limit: z.number().int().min(1).max(24000).default(12000),
      }).strict(),
      execute: (args, signal) => call('read_recording', args, signal),
    },
    {
      name: 'relabel_recording_speakers',
      description: 'Relabel anonymous ([说话人 N]) or misattributed speaker spans in a recording and sync back to iPhone voiceprints. IMPORTANT: If the old label was ALREADY a named person or "我" and only specific turns were misattributed, pass exact span_ids and scope="selection" so that person\'s other turns are preserved; use scope="cluster" only when relabeling an entire anonymous [说话人 N] cluster.',
      schema: z.object({
        source_id: z.string().min(1).max(200),
        target_speaker: z.string().trim().min(1).max(64),
        is_owner: z.boolean().default(false),
        from_speaker: z.string().max(64).optional(),
        span_ids: z.array(z.string().min(1)).max(200).optional(),
        scope: z.enum(['cluster', 'selection']).default('selection'),
        reason: z.string().max(400).default(''),
      }).strict(),
      execute: (args, signal) => call('relabel_recording_speakers', args, signal),
    },
  ]
}
