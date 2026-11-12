import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { Ticket } from '../src/core/index.ts'
import type { ExecutorToolsHost } from '../src/app/tools/executor.ts'
import { momoPimTools } from '../src/app/tools/momo-pim.ts'

let directory: string
let ticket: Ticket
const get = vi.fn(() => ticket)
const host = { store: { tickets: { get } } } as unknown as ExecutorToolsHost

beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'momo-pim-test-'))
  await mkdir(join(directory, 'superagent/state'), { recursive: true })
  await writeFile(join(directory, 'superagent/state/momo-bridge.json'), JSON.stringify({ secret: 'pim-secret' }))
  vi.stubEnv('MOMO_DATA_DIR', directory)
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', 'http://127.0.0.1:12345')
  ticket = { id: 'ticket-pim-1', assignments: [{ id: 'run-pim-1', state: 'running' }] } as Ticket
})

afterEach(async () => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
  await rm(directory, { recursive: true, force: true })
})

it('registers all Reminders/Calendar/Notes, Recording & Dream Notebook tools only in a loopback MoMo host', () => {
  const names = momoPimTools(host, ticket.id).map(t => t.name)
  expect(names).toHaveLength(30)
  expect(names).toContain('create_reminder')
  expect(names).toContain('complete_reminder')
  expect(names).toContain('create_calendar_event')
  expect(names).toContain('create_note')
  expect(names).toContain('list_memory_notebooks')
  expect(names).toContain('read_memory_notebook')
  expect(names).toContain('write_memory_notebook')
  expect(names).toContain('move_memory_notebook')
  expect(names).toContain('remove_memory_notebook')
  expect(names).toContain('update_core_memory')
  expect(names).toContain('list_recordings')
  expect(names).toContain('search_recordings')
  expect(names).toContain('read_recording')
  expect(names).toContain('relabel_recording_speakers')
  expect(names).toContain('exclude_recording_speaker')
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', '')
  expect(momoPimTools(host, ticket.id)).toEqual([])
  vi.stubEnv('MOMO_COMPUTER_BRIDGE', 'https://outside.example')
  expect(() => momoPimTools(host, ticket.id)).toThrow('loopback')
})

it('injects ticket authority outside the schema and calls /momo/internal/superagent/pim', async () => {
  const receipt = { ok: true, state: 'succeeded', resource: { kind: 'reminder', id: 'rem-1', fields: { title: '跟进合同' } } }
  const fetch = vi.fn().mockResolvedValue({ ok: true, json: async () => receipt })
  vi.stubGlobal('fetch', fetch)
  const createReminder = momoPimTools(host, ticket.id).find(t => t.name === 'create_reminder')!
  expect(createReminder.schema.safeParse({ title: '跟进合同', ticket_id: 'other' }).success).toBe(false)
  const parsed = createReminder.schema.parse({ title: '跟进合同', due_at: '2026-11-06T10:00:00+08:00' })
  expect(await createReminder.execute(parsed, new AbortController().signal)).toEqual(receipt)
  const [url, init] = fetch.mock.calls[0]!
  expect(String(url)).toBe('http://127.0.0.1:12345/momo/internal/superagent/pim')
  expect(init.headers['x-momo-bridge']).toBe('pim-secret')
  expect(JSON.parse(init.body)).toEqual({
    ticket_id: 'ticket-pim-1',
    assignment_id: 'run-pim-1',
    op: 'create_reminder',
    args: {
      title: '跟进合同',
      due_at: '2026-11-06T10:00:00+08:00',
      notes: '',
      priority: 0,
      list_name: '',
      list_id: '',
      remind_at: '',
    },
  })
})

it('aborts cleanly and refuses stopped tickets before calling the bridge', async () => {
  const fetch = vi.fn()
  vi.stubGlobal('fetch', fetch)
  const searchReminders = momoPimTools(host, ticket.id).find(t => t.name === 'search_reminders')!
  ticket = { ...ticket, assignments: [] }
  await expect(searchReminders.execute(searchReminders.schema.parse({}), new AbortController().signal)).rejects.toThrow('not running')
  const controller = new AbortController()
  controller.abort()
  await expect(searchReminders.execute(searchReminders.schema.parse({}), controller.signal)).rejects.toThrow()
  expect(fetch).not.toHaveBeenCalled()
})
