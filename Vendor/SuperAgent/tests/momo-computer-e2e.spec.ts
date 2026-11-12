/** Opt-in native GUI journey, driven by Tests/Support/run-agent-desktop-e2e.py. */
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import type { Ticket } from '../src/core/index.ts'
import type { ExecutorToolsHost } from '../src/app/tools/executor.ts'
import { momoComputerTools } from '../src/app/tools/momo-computer.ts'

it.runIf(!!process.env.MOMO_DESKTOP_E2E)('operates the real AppKit fixture through the authenticated native bridge', async () => {
  const output = process.env.MOMO_DESKTOP_E2E!
  expect(await readFile(join(output, '.desktop-e2e-owned'), 'utf8')).toBe('MoMo disposable desktop E2E\n')
  let ticket = { id: 'desktop-e2e-ticket', assignments: [{ id: 'desktop-e2e-assignment', state: 'running' }] } as Ticket
  const host = { store: { tickets: { get: () => ticket } } } as unknown as ExecutorToolsHost
  const tools = momoComputerTools(host, ticket.id)
  const call = async (name: string, args: unknown) => {
    const tool = tools.find(item => item.name === name)!
    return await tool.execute(tool.schema.parse(args), new AbortController().signal) as Record<string, unknown>
  }
  const ref = (tree: unknown, name: string): string => {
    const found: string[] = []
    const visit = (value: unknown) => {
      if (!value || typeof value !== 'object') return
      const node = value as Record<string, unknown>
      if (node.name === name && typeof node.ref_id === 'string') found.push(node.ref_id)
      for (const child of Object.values(value)) visit(child)
    }
    visit(tree); expect(found).toHaveLength(1); return found[0]!
  }
  const snapshot = async () => {
    const tree = await call('computer_snapshot', { app: 'MoMo Desktop Fixture' })
    expect(tree.ok).toBe(true); return tree
  }
  let tree = await snapshot()
  const text = 'SuperAgent 原生电脑工具 E2E 通过'
  expect((await call('computer_action', { ref: ref(tree, '测试内容'), action: 'set_value', text })).ok).toBe(true)
  tree = await snapshot()
  expect((await call('computer_action', { ref: ref(tree, '启用测试选项'), action: 'toggle' })).ok).toBe(true)
  tree = await snapshot()
  expect((await call('computer_action', { ref: ref(tree, '保存测试内容'), action: 'click' })).ok).toBe(true)
  await expect.poll(async () => JSON.parse(await readFile(join(output, 'fixture-state.json'), 'utf8'))).toEqual({ saves: 1, text, checked: true })
  expect(JSON.stringify(await snapshot())).toContain(text)
  ticket = { ...ticket, assignments: [] }
  await expect(call('computer_snapshot', { app: 'MoMo Desktop Fixture' })).rejects.toThrow('not running')
}, 30000)
