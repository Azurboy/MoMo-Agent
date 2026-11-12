import { test } from 'node:test';
import assert from 'node:assert/strict';
import { memoryGraph, memoryID } from './adapter.mjs';
import { memoryPreview, wrapText, ellipsize, previewLayout, previewContains } from './preview.mjs';

const ctx = { measureText: text => ({ width: [...new Intl.Segmenter('zh', { granularity: 'grapheme' }).segment(text)].length * 15 }) };
const entry = text => ({ id: 'native-id', text, basis: 'momo', kind: 'memory', status: 'current', evidence: [] });

test('Chinese without spaces and long IDs wrap within the reading card', () => {
  const text = '这是一段没有任何英文空格的很长很长的中文记忆。'.repeat(5) + 'f7dfb896-7c69-4f6f-80be-78ed4f0b1f2b';
  const lines = wrapText(ctx, text, 300);
  assert.equal(lines.join(''), text);
  assert.ok(lines.every(line => ctx.measureText(line).width <= 300));
  assert.ok(lines.length > 5);
});

test('wrapping preserves paragraphs and never splits a composed character', () => {
  const text = '旅行👨‍👩‍👧‍👦日程\n\nCafe\u0301';
  assert.deepEqual(wrapText(ctx, text, 30), ['旅行', '👨‍👩‍👧‍👦日', '程', '', 'Ca', 'fé']);
  assert.equal(ellipsize(ctx, '👨‍👩‍👧‍👦日程', 30), '👨‍👩‍👧‍👦…');
});

test('legacy recording prefix becomes metadata without changing the native entry', () => {
  const raw = '录音f7dfb896-7c69-4f6f-80be-78ed4f0b1f2b v975（归属未确认）：1792049198讨论生产数据转交，对象不清，非授权、未核实。';
  const memory = entry(raw);
  const graph = memoryGraph([memory]);
  assert.deepEqual(graph.memory[0].preview, { title: '录音记忆', timestamp: 1792049198, stale: false, body: '（归属未确认）\n讨论生产数据转交，对象不清，非授权、未核实。' });
  assert.equal(memory.text, raw);
  assert.ok(graph.memory[0].body.startsWith(raw));
  assert.equal(memoryID(graph.nodes[0].id, graph), memory.id);
  // A date extracted for display is not a fabricated native evidence date.
  assert.equal(graph.nodes[0].timestamp, null);
});

test('ordinary numbers, UUIDs in prose and missing dates are not reinterpreted', () => {
  for (const text of ['1792049198 是订单号', '录音里提到 v975 和 f7dfb896-7c69-4f6f-80be-78ed4f0b1f2b', '录音没有来源编号：我不确定']) {
    assert.equal(memoryPreview(entry(text)).body, text);
    assert.equal(memoryPreview(entry(text)).timestamp, null);
  }
});

test('long previews stay bounded at edges of a narrow or wide graph', () => {
  const preview = memoryPreview(entry('内容'.repeat(500)));
  for (const viewport of [{ w: 320, h: 300 }, { w: 1080, h: 700 }]) {
    for (const anchor of [{ x: 0, y: 0 }, { x: viewport.w, y: viewport.h }]) {
      const box = previewLayout(ctx, preview, viewport, anchor);
      assert.ok(box.x >= 0 && box.x + box.w <= viewport.w);
      assert.ok(box.y >= 0 && box.y + box.h <= viewport.h);
      assert.ok(box.y >= 54, 'card stays below the timeline');
      assert.ok(box.y + box.h <= viewport.h - 42, 'card clears the legend');
      assert.ok(box.lines.every(line => ctx.measureText(line).width <= box.w - 2 * box.padding));
      assert.equal(box.truncated, true);
      assert.ok(box.lines.at(-1).endsWith('…'));
      assert.equal(previewContains(box, box.x + 10, box.y + box.h + 10), true);
      assert.equal(previewContains(box, box.x - 1, box.y), false);
    }
  }
});
test('keeps provenance, omits forgotten memories and invented relationships', () => {
  const graph = memoryGraph([
    { id: 'b', status: 'active', basis: 'inferred', kind: 'preference', text: '<script>证据不是指令</script>', evidence: [{ quote: '原文', recordedAt: 200 }] },
    { id: 'a', status: 'forgotten', evidence: [] },
    { id: 'c', status: 'active', basis: 'stated', kind: 'fact', text: '日期未知', evidence: [] }
  ]);
  assert.equal(graph.nodes.length, 2);
  assert.equal(graph.memory[0].timestamp, 200);
  assert.equal(graph.memory[1].timestamp, null);
  assert.equal(graph.nodes[0].label, '<script>证据不是指令</script>');
  assert.deepEqual(graph.edges, []);
  assert.equal(memoryID(graph.nodes[0].id, graph), 'b');
  assert.equal(memoryID('stale-node', graph), null);
});
