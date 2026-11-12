import { isEn, memoryPreview } from './preview.mjs';

export function memoryGraph(memories) {
  const active = memories.filter(m => m.status !== 'forgotten').slice().sort((a,b) => a.id.localeCompare(b.id));
  const cards = active.map(m => {
    const dates = m.evidence.map(e => e.recordedAt).filter(Number.isFinite);
    return {
      source: 'memory', fingerprint: m.id, timestamp: dates.length ? Math.min(...dates) : null, preview: memoryPreview(m),
      title: m.text, body: `${m.text}\n\n${['momo', 'hermes'].includes(m.basis) ? (m.kind === 'user' ? (isEn() ? 'About You' : '关于你') : (isEn() ? "MoMo's Memory" : 'MoMo 的记忆')) : m.basis === 'inferred' ? (isEn() ? 'Inferred' : '推断') : (isEn() ? 'Explicitly stated' : '明确陈述')} · ${m.kind}\n${m.evidence.map(e => `「${e.quote}」`).join('\n')}`
    };
  });
  const nodes = cards.map((c,i) => ({ id: `memory:memory:${i}:${c.fingerprint}`, label: c.title,
    kind: 'memory', memorySource: 'memory', timestamp: c.timestamp, category: active[i].kind,
    useCount: 0, state: active[i].status, createdBy: null, pinned: false }));
  // No inferred relationships or invented skill usage counts.
  return { nodes, edges: [], clusters: [], memory: cards, stats: { memory: cards.length } };
}
export function memoryID(nodeID, graph) {
  const index = graph.nodes.findIndex(n => n.id === nodeID);
  return index < 0 ? null : graph.memory[index].fingerprint;
}
