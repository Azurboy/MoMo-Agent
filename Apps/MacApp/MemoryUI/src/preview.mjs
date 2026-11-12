// Presentation only. The native reader always receives the unchanged memory ID
// and displays the complete, original memory entry.
const segments = new Intl.Segmenter('zh', { granularity: 'grapheme' });
const graphemes = text => Array.from(segments.segment(text), item => item.segment);
export const isEn = () => typeof window !== 'undefined' && !/^zh\b/i.test(navigator?.language || 'zh');

export function wrapText(ctx, text, width) {
  const lines = [];
  for (const paragraph of text.split(/\r?\n/)) {
    let line = '';
    for (const character of graphemes(paragraph)) {
      const next = line + character;
      if (line && ctx.measureText(next).width > width) {
        lines.push(line.trimEnd());
        line = character.trimStart();
      } else line = next;
    }
    lines.push(line.trimEnd());
  }
  return lines;
}

export function ellipsize(ctx, text, width) {
  if (ctx.measureText(text).width <= width) return text;
  const characters = graphemes(text);
  while (characters.length && ctx.measureText(characters.join('').trimEnd() + '…').width > width) characters.pop();
  return characters.join('').trimEnd() + '…';
}

export function memoryPreview(memory) {
  let body = memory.text;
  let title = memory.kind === 'user' ? (isEn() ? 'About You' : '关于你') : (isEn() ? "MoMo's Memory" : 'MoMo 的记忆');
  let timestamp = memory.evidence.map(e => e.recordedAt).find(Number.isFinite) ?? null;
  // Old transcript entries have an exact machine-generated source prefix. Move
  // only that prefix out of the preview; uncertainty and all following prose stay.
  const prefix = /^录音\s*[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}\s*(?:v\d+\s*)?(（[^）]*）)?\s*[:：]\s*(\d{10})?(?=\D|$)/i.exec(body);
  if (prefix) {
    title = isEn() ? 'Recording Memory' : '录音记忆';
    body = (prefix[1] ? prefix[1] + '\n' : '') + body.slice(prefix[0].length);
    if (prefix[2]) timestamp = Number(prefix[2]);
  }
  return { title, body, timestamp, stale: memory.status === 'stale' };
}

export function previewLayout(ctx, preview, viewport, anchor) {
  const padding = 20, margin = 12, lineHeight = 24;
  // The timeline and legend are HTML overlays above the canvas. Keep the card
  // inside their clear area, including in short/narrow windows.
  const top = Math.min(72, viewport.h * 0.18);
  const bottom = Math.min(56, viewport.h * 0.14);
  const width = Math.max(1, Math.min(420, viewport.w - margin * 2));
  const textWidth = Math.max(1, width - padding * 2);
  ctx.font = '15px -apple-system, BlinkMacSystemFont, sans-serif';
  const wrapped = wrapText(ctx, preview.body, textWidth);
  const limit = Math.max(1, Math.min(6, Math.floor((viewport.h - top - bottom - 102) / lineHeight)));
  const lines = wrapped.slice(0, limit);
  const truncated = wrapped.length > limit;
  if (truncated) lines[lines.length - 1] = ellipsize(ctx, lines.at(-1) + '…', textWidth);
  const height = padding * 2 + 20 + 12 + lines.length * lineHeight + 12 + 18;
  const x = Math.max(margin, Math.min(anchor.x - width / 2, viewport.w - width - margin));
  const y = Math.max(top, Math.min(anchor.y - height - 20, viewport.h - height - bottom));
  return { x, y, w: width, h: height, lines, truncated, padding, lineHeight };
}

export function drawMemoryPreview(ctx, node, card, viewport, anchor, dark) {
  const preview = card?.preview ?? { title: isEn() ? "MoMo's Memory" : 'MoMo 的记忆', body: node.label, timestamp: null };
  const box = previewLayout(ctx, preview, viewport, anchor);
  const { x, y, w, h, padding, lineHeight } = box;
  const muted = dark ? '#bcbcb7' : '#656560';
  ctx.save();
  ctx.globalAlpha = 1;
  ctx.shadowColor = dark ? '#00000040' : '#00000016';
  ctx.shadowBlur = 20; ctx.shadowOffsetY = 4;
  ctx.fillStyle = dark ? '#292927' : '#ffffff';
  ctx.beginPath(); ctx.roundRect(x, y, w, h, 16); ctx.fill();
  ctx.shadowColor = 'transparent';
  ctx.strokeStyle = dark ? '#454541' : '#e3e3de';
  ctx.lineWidth = 1; ctx.stroke();
  ctx.textAlign = 'left'; ctx.textBaseline = 'top';
  ctx.fillStyle = muted;
  ctx.font = '500 12px -apple-system, BlinkMacSystemFont, sans-serif';
  ctx.fillText(preview.title, x + padding, y + padding);
  if (preview.timestamp && Number.isFinite(new Date(preview.timestamp * 1000).getTime())) {
    const date = new Date(preview.timestamp * 1000);
    const formatted = new Intl.DateTimeFormat(isEn() ? 'en-US' : 'zh-CN', { year: 'numeric', month: 'short', day: 'numeric' }).format(date);
    ctx.textAlign = 'right';
    ctx.fillText(formatted, x + w - padding, y + padding);
    ctx.textAlign = 'left';
  }
  ctx.fillStyle = dark ? '#f3f3ee' : '#242422';
  ctx.font = '15px -apple-system, BlinkMacSystemFont, sans-serif';
  box.lines.forEach((line, i) => ctx.fillText(line, x + padding, y + padding + 32 + i * lineHeight));
  ctx.font = '12px -apple-system, BlinkMacSystemFont, sans-serif';
  ctx.fillStyle = muted;
  ctx.fillText(preview.stale ? (isEn() ? 'Source updated · Click to read' : '原文已改变 · 点击查看全文') : box.truncated ? (isEn() ? 'Preview · Click to read full memory' : '记忆预览 · 点击查看全文') : (isEn() ? 'Click to view full memory' : '点击查看完整记忆'), x + padding, y + h - padding - 16);
  ctx.restore();
  return { x, y, w, h };
}

export function previewContains(rect, x, y) {
  // Include the small gap to the node, so moving onto the card keeps it open.
  return !!rect && x >= rect.x && x <= rect.x + rect.w && y >= rect.y && y <= rect.y + rect.h + 24;
}
