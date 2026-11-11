/** Resolves and seeds per-role default models on newly created sessions without mutating the global DSH default. */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent, ModelSelection } from '@deepseek-ai/dsh-agent'
import { ReasoningEffortId } from '@deepseek-ai/dsh-llm'
import type { RoleModel } from '../policy.ts'

/** Resolve a configured route through the live provider; catalog membership is not a restriction. */
export async function resolveRoleModel(ctx: Context, model: RoleModel): Promise<ModelSelection> {
  const value = await ctx.llm.resolveCallConfig({ provider: model.provider, model: model.model,
    ...(model.reasoningEffort ? { reasoningEffort: ReasoningEffortId(model.reasoningEffort) } : {}) })
  return { provider: value.provider, model: value.model, ...(value.reasoningEffort ? { reasoningEffort: value.reasoningEffort } : {}) }
}

function sameSelection(left: ModelSelection | undefined, right: ModelSelection): boolean {
  return left !== undefined
    && left.provider === right.provider
    && left.model === right.model
    && (left.reasoningEffort ?? undefined) === (right.reasoningEffort ?? undefined)
}

function currentSessionSelection(agent: Agent): ModelSelection | undefined {
  const events = agent.session.snapshotEvents()
  for (let i = events.length - 1; i >= 0; i--) {
    const event = events[i]!
    if (event.type === 'model/selection' && event.data && typeof event.data === 'object') {
      const sel = event.data as ModelSelection
      if (sel.provider && sel.model) return sel
    }
    if (event.type === 'request/header' && event.data && typeof event.data === 'object') {
      const cfg = (event.data as { header?: { config?: ModelSelection } }).header?.config
      if (cfg?.provider && cfg?.model) return cfg
    }
  }
  const header = agent.session.requestHeader()?.config
  return header?.provider && header?.model ? header : undefined
}

const activeOverrides = new WeakMap<Agent, { update(selection: ModelSelection): void }>()

function installSelectionOverride(ctx: Context, agent: Agent, initialSelection: ModelSelection): void {
  const existing = activeOverrides.get(agent)
  if (existing) {
    existing.update(initialSelection)
    return
  }
  let pending: ModelSelection | undefined = initialSelection
  let assembled: ModelSelection | undefined
  const controller = {
    update(selection: ModelSelection) {
      pending = selection
    },
  }
  activeOverrides.set(agent, controller)
  agent.ctx.effect(() => {
    const disposers = [
      agent.ctx.on('system-prompt/assemble', async (_assembly, _context, next) => {
        const selection = pending
        const result = await next()
        assembled = selection
        return selection ? { ...result, variables: { ...result.variables, provider: selection.provider, model: selection.model } } : result
      }, { prepend: true }),
      agent.ctx.on('agent/request', async (_payload, next) => {
        const result = await next()
        if (!assembled) return result
        const { reasoningEffort: _inherited, ...rest } = result
        return { ...rest, ...assembled }
      }, { prepend: true }),
      ctx.on('session/event', (session, event) => {
        if (session !== agent.session || !pending) return
        if (event.type === 'model/selection') {
          const nextSel = event.data as ModelSelection | undefined
          if (nextSel && !sameSelection(pending, nextSel)) pending = undefined
        } else if (event.type === 'request/header') {
          const cfg = (event.data as { header?: { config?: ModelSelection } } | undefined)?.header?.config
          if (!cfg || sameSelection(pending, cfg)) pending = undefined
        }
      }),
    ]
    return () => {
      activeOverrides.delete(agent)
      disposers.forEach(dispose => dispose())
    }
  })
}

/** Actively align an existing or newly created session with its configured role model without mutating the global DSH default. */
export async function syncRoleModel(ctx: Context, agent: Agent, model: RoleModel | null): Promise<void> {
  if (!model) return
  const current = currentSessionSelection(agent)
  if (current && current.provider === model.provider && current.model === model.model
    && (current.reasoningEffort ?? undefined) === (model.reasoningEffort ?? undefined)) return
  const selected = await resolveRoleModel(ctx, model)
  if (sameSelection(current, selected)) return
  installSelectionOverride(ctx, agent, selected)
  agent.session.append('model/selection', selected)
  await ctx.sessionPersistence.flush()
}

/** Seed a role's configured model onto a brand-new session before its first request, or sync resumed sessions in MoMo desktop mode. */
export async function initializeRoleModel(ctx: Context, agent: Agent, model: RoleModel | null): Promise<void> {
  if (!model) return
  const hasExisting = Boolean(agent.session.requestHeader() || agent.session.snapshotEvents().some(event => event.type === 'model/selection'))
  if (hasExisting && !process.env.MOMO_DATA_DIR?.trim()) return
  await syncRoleModel(ctx, agent, model)
}
