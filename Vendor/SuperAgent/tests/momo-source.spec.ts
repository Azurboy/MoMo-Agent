import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Context } from '@deepseek-ai/cordis'
import { Setup } from '../src/app/setup.ts'
import { Commands } from '../src/infra/commands.ts'
import { HealthBoard } from '../src/infra/health.ts'
import { workerGitConfig } from '../src/infra/environment.ts'
import { KV } from '../src/kv.ts'
import { isCreatorRequest } from '../src/executor/dsh.ts'
import { SettingsSchema, settingsPolicy } from '../src/policy.ts'
import { MomoConfigSchema, SOURCE, momoKind, momoThreadContext, momoTrigger, pollMomoOnce, sendMomo } from '../src/sources/momo.ts'
import { SourceRegistry } from '../src/sources/registry.ts'
import type { SourceContext } from '../src/sources/host.ts'
import type { ReceiveResult, Thread, Trigger } from '../src/core/index.ts'
import { testMachine } from './fixtures/deployment.ts'

const emptyThread = (id: string): Thread => ({
  key: `momo:${id}`,
  ref: { source: SOURCE, id },
  createdAt: '2026-10-31T00:00:00.000Z',
  subscriptions: [],
  correlated: [],
  pending: [],
  meta: {},
})

let dir: string
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'momo-source-'))
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('GitHub-optional Personal Agent setup', () => {
  it('configures cleanly when sources.github.enabled is false without a GitHub repository or gh CLI', async () => {
    const stateDir = join(dir, 'state')
    mkdirSync(stateDir, { recursive: true })
    const machine = testMachine({ stateDir })
    const reader = (text: string) => ({ readFrom: () => ({ text, nextOffset: text.length, lossy: false }) })
    const subprocess = {
      spawn: () => ({
        done: Promise.resolve({ exitCode: 1, signal: null }),
        collected: { stdout: reader(''), stderr: reader('no git or gh needed') },
      }),
    }
    const ctx = { subprocess, logger: { warn: () => {} } } as unknown as Context
    const controller = new AbortController()
    const setup = new Setup({ context: ctx, machine, lifetime: controller.signal, restart: () => {} })
    try {
      const settings = SettingsSchema.parse({
        sources: { github: { enabled: false, config: {} }, momo: { enabled: true, config: {} } },
      })
      expect(await setup.run(settings)).toBe(true)
      expect(setup.configured()).toBe(true)
      expect(setup.deployment.repository).toBe('')
      expect(setup.deployment.github.cli).toBe('')
      expect(readFileSync(workerGitConfig(stateDir), 'utf8')).not.toContain('[credential "https://github.com"]')
      expect(readFileSync(join(stateDir, 'worker-bin', 'gh'), 'utf8')).toContain('has no GitHub repository')
      await expect(setup.checkAccounts('source:momo', settings)).resolves.toBeUndefined()
      await expect(setup.checkAccounts('source:github', settings)).resolves.toBeUndefined()
    } finally {
      setup.restore()
      controller.abort()
    }
  })
})

describe('momoKind policy and loopback bridge', () => {
  it('rejects non-loopback bridge URLs and gates explicit chat vs proactive unaddressed transcripts', () => {
    expect(() => MomoConfigSchema.parse({ bridgeUrl: 'https://example.com' })).toThrow('loopback')
    const settings = SettingsSchema.parse({
      sources: {
        github: { enabled: false, config: {} },
        momo: { enabled: true, config: { bridgeUrl: 'http://127.0.0.1:18787', transcripts: 'all', lifeSignals: 'all', chat: true } },
      },
      policy: {
        rules: [{ id: 'commitment', name: 'Personal commitment', enabled: true, instruction: 'Explicit commitments made in voice recordings.' }],
        sources: { momo: { allowed: [{ id: 'owner', name: 'User' }], admission: {} } },
      },
      eval: { mode: 'auto' },
    })
    const board = new HealthBoard()
    const sources = new SourceRegistry(() => settings, board)
    sources.register(momoKind)
    const policy = settingsPolicy(settings, sources)

    const chatTrigger = momoTrigger({
      cursor: '1', id: 'msg-1', stream: 'chat', chat_mode: 'creator', thread_id: 'chat:1',
      actor_id: 'owner', actor_name: 'User', human: true, addressed: 'direct',
      at: '2026-10-31T10:00:00.000Z', text: '帮我整理今天的待办', reply_allowed: true,
    }, 'http://127.0.0.1:18787')
    expect(isCreatorRequest(chatTrigger)).toBe(true)
    expect(isCreatorRequest({ ...chatTrigger, actor: { source: SOURCE, id: 'guest' } })).toBe(false)
    expect(policy.gate(chatTrigger, emptyThread('chat:1'), [])).toMatchObject({ admissible: true, strength: 'explicit' })

    const transcriptTrigger = momoTrigger({
      cursor: '2', id: 'span-1', stream: 'transcripts', chat_mode: 'creator', thread_id: 'transcript:rec-1',
      actor_id: 'owner', actor_name: 'User', human: true,
      at: '2026-10-31T10:05:00.000Z', text: '我一会儿把项目复盘清单整理出来发给大家。',
      source_id: 'rec-1', reply_allowed: true,
    }, 'http://127.0.0.1:18787')
    expect(isCreatorRequest(transcriptTrigger)).toBe(false)
    expect(policy.gate(transcriptTrigger, emptyThread('transcript:rec-1'), [])).toMatchObject({
      admissible: true,
      strength: 'inferred',
      basis: { via: 'admission', source: SOURCE, row: 'transcripts', cell: 'listedUnaddressed' },
    })

    const participatingThread: Thread = {
      ...emptyThread('transcript:rec-1'),
      subscriptions: ['tkt-existing'],
    }
    expect(policy.gate(transcriptTrigger, participatingThread, [])).toMatchObject({
      admissible: true,
      strength: 'inferred',
      basis: { via: 'admission', source: SOURCE, row: 'transcripts', cell: 'listedUnaddressed' },
    })

    const otherSpeakerTrigger = momoTrigger({
      cursor: '3', id: 'span-2', stream: 'transcripts', thread_id: 'transcript:rec-1',
      actor_id: 'other', actor_name: 'Other Speaker', human: true,
      at: '2026-10-31T10:06:00.000Z', text: '[他人:同事] 我去把那个接口改一下。',
      source_id: 'rec-1', reply_allowed: true,
    }, 'http://127.0.0.1:18787')
    expect(policy.gate(otherSpeakerTrigger, emptyThread('transcript:rec-1'), [])).toEqual({
      admissible: false,
      reason: 'not_a_member',
    })
    expect(policy.gate(otherSpeakerTrigger, participatingThread, [])).toEqual({
      admissible: false,
      reason: 'not_a_member',
    })

    const offSettings = SettingsSchema.parse({ ...settings, eval: { mode: 'off' } })
    const offSources = new SourceRegistry(() => offSettings, new HealthBoard())
    offSources.register(momoKind)
    const offPolicy = settingsPolicy(offSettings, offSources)
    expect(offPolicy.gate(transcriptTrigger, emptyThread('transcript:rec-1'), [])).toMatchObject({ admissible: false })
  })

  it('polls triggers, reads thread context, and posts outbound messages with bridge secret', async () => {
    const stateDir = join(dir, 'state')
    mkdirSync(stateDir, { recursive: true })
    writeFileSync(join(stateDir, 'momo-bridge.json'), JSON.stringify({ secret: 'bridge-secret-123' }), { mode: 0o600 })

    const outboundReceived: unknown[] = []
    const seenHeaders: string[] = []
    const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
      seenHeaders.push(String(req.headers['x-momo-bridge'] ?? ''))
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      if (req.method === 'GET' && url.pathname === '/momo/internal/superagent/triggers') {
        const after = url.searchParams.get('after') ?? ''
        const events = after === 'c2' ? [] : [
          { cursor: 'c1', id: 'm1', stream: 'transcripts', thread_id: 'transcript:s1', actor_id: 'owner', human: true,
            at: '2026-10-31T12:00:00.000Z', text: '我下午三点前整理好周报。', title: '晨会录音', source_id: 's1', reply_allowed: true },
          { cursor: 'c2', id: 'm2', stream: 'chat', thread_id: 'chat:1', actor_id: 'owner', human: true, addressed: 'direct',
            at: '2026-10-31T12:01:00.000Z', text: '看看刚才的录音', parent_id: 'm1', reply_allowed: true },
        ]
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ events, next_cursor: 'c2' }))
        return
      }
      if (req.method === 'GET' && url.pathname === '/momo/internal/superagent/context') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({
          messages: [
            { id: 'm0', from: 'owner', at: '2026-10-31T11:59:00.000Z', text: '今天先同步进度。' },
            { id: 'm1', from: 'owner', at: '2026-10-31T12:00:00.000Z', text: '我下午三点前整理好周报。' },
          ],
          body: { source_id: url.searchParams.get('source_id') },
        }))
        return
      }
      if (req.method === 'POST' && url.pathname === '/momo/internal/superagent/outbound') {
        const chunks: Buffer[] = []
        for await (const chunk of req) chunks.push(Buffer.from(chunk))
        outboundReceived.push(JSON.parse(Buffer.concat(chunks).toString('utf8')))
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ status: 'sent' }))
        return
      }
      res.writeHead(404); res.end()
    })
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
    const address = server.address() as { port: number }
    const bridgeUrl = `http://127.0.0.1:${address.port}`
    const config = MomoConfigSchema.parse({ bridgeUrl, waitMs: 0, pollIntervalMs: 100 })
    const deployment = { ...testMachine({ stateDir }), repository: '', github: { cli: '', login: 'local-agent', noreply: 'local-agent@localhost' } }
    const commands = new Commands(() => deployment, {}, new AbortController().signal)
    const kv = new Map<string, unknown>()
    const ingested: Trigger[] = []
    const described = new Map<string, string>()
    const fakeCtx = {
      deployment,
      commands,
      state: {
        get: (k: string) => kv.get(k),
        set: (k: string, v: unknown) => { if (v === undefined) kv.delete(k); else kv.set(k, v) },
      },
      receive: (trigger: Trigger): ReceiveResult => { ingested.push(trigger); return 'stored' },
      threads: { describe: (k: string, d: { label?: string }) => { if (d.label) described.set(k, d.label) } },
    } as unknown as SourceContext

    try {
      const count = await pollMomoOnce(fakeCtx, config, new AbortController().signal)
      expect(count).toBe(2)
      expect(kv.get(KV.momo.cursor)).toBe('c2')
      expect(ingested.map(item => [item.id, item.addressed ?? 'unaddressed'])).toEqual([
        ['momo:m1', 'unaddressed'],
        ['momo:m2', 'direct'],
      ])
      expect(momoKind.repliesTo!(ingested[1]!)).toBe('momo:m1')
      expect(described.get('momo:transcript:s1')).toBe('晨会录音')
      const envVars = momoKind.environment!.values({ deployment, config, trigger: ingested[0]! })
      expect(envVars.DSH_SUPERAGENT_MOMO_CLI).toBe(join(stateDir, 'momo-cli'))
      expect(envVars.DSH_SUPERAGENT_MOMO_WORKSPACE).toBeTruthy()
      expect(envVars.DSH_SUPERAGENT_MOMO_SOURCE_ID).toBe('s1')

      const contextPage = await momoThreadContext.read(commands, ingested[0]!, 'thread', undefined, config)
      expect(contextPage.messages).toHaveLength(2)
      expect(contextPage.body).toEqual({ source_id: 's1' })

      const sent = await sendMomo({ commands }, {
        id: 'reply-1',
        kind: 'reply',
        ticketId: 'ticket-1',
        attentionId: 'question-1',
        text: '周报要覆盖上周吗？',
        channel: ingested[0]!.channel!,
      })
      expect(sent).toBe('sent')
      expect(outboundReceived).toEqual([expect.objectContaining({ id: 'reply-1', ticket_id: 'ticket-1', attention_id: 'question-1', text: '周报要覆盖上周吗？' })])
      expect(seenHeaders.every(value => value === 'bridge-secret-123')).toBe(true)
    } finally {
      await new Promise<void>(resolve => server.close(() => resolve()))
    }
  })
})
