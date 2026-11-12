import { build } from 'esbuild';
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const root = path.dirname(fileURLToPath(import.meta.url));
const upstream = path.resolve(root, '../../../Vendor/HermesAgent/apps/desktop/src');
const out = path.resolve(root, '../Desktop/MemoryWeb');
await mkdir(out, { recursive: true });
const adapters = {
  './node-context-menu': 'node-menu.tsx', './share-controls': 'share-controls.tsx',
  '@/components/ui/codicon': 'codicon.tsx', 'momo-memory-preview': 'preview.mjs', 'momo-memory-reader': 'main.tsx'
};
function replaceOnce(source, from, to) {
  if (source.split(from).length !== 2) throw new Error(`Hermes UI changed; review adapter: ${from.slice(0, 70)}`);
  return source.replace(from, to);
}
await build({
  entryPoints: [path.join(root, 'src/main.tsx')], outfile: path.join(out, 'memory.js'),
  bundle: true, minify: true, jsx: 'automatic', target: 'safari17', format: 'iife',
  nodePaths: [path.join(root, 'node_modules')], define: { 'process.env.NODE_ENV': '"production"' },
  plugins: [{ name: 'momo-memory-adapter', setup(plugin) {
    plugin.onResolve({ filter: /^(@\/|\.\/node-context-menu$|\.\/share-controls$|momo-memory-)/ }, args => {
      if (adapters[args.path]) return { path: path.join(root, 'src', adapters[args.path]) };
      if (args.path.startsWith('@/')) return { path: path.join(upstream, args.path.slice(2)) + '.ts' };
    });
    plugin.onLoad({ filter: /starmap\/star-map\.tsx$/ }, async args => {
      let source = await readFile(args.path, 'utf8');
      // This adapter supplies only MoMo memories. Keep the upstream renderer and timeline,
      // omit the skill legend and sharing UI that have no MoMo counterpart.
      source = replaceOnce(source, '<span className="flex items-center gap-1.5">\n          <span className="inline-block size-2 rounded-full bg-[var(--theme-primary)]/80" /> skill\n        </span>', '');
      source = source.replace(' /> memory', ' /> {(/^zh\\b/i.test(navigator?.language || "zh") ? "记忆" : "memory")}').replace('core = oldest · outer = newer', '{(/^zh\\b/i.test(navigator?.language || "zh") ? "位置不代表时间 · 与 MoMo 共用记忆" : "position ≠ time · shared memory with MoMo")}');
      source = `import { inspectNode } from 'momo-memory-reader';\n` + source;
      source = `import { previewContains } from 'momo-memory-preview';\n` + source;
      source = replaceOnce(source, 'const hoverRef = useRef<null | string>(null)', 'const previewRef = useRef(null);\n  const hoverRef = useRef<null | string>(null)');
      source = replaceOnce(source, 'const { animating, ringLabelRects } = drawScene({', 'const { animating, ringLabelRects, previewHit } = drawScene({');
      source = replaceOnce(source, 'ringLabelRectsRef.current = ringLabelRects', 'ringLabelRectsRef.current = ringLabelRects; previewRef.current = previewHit');
      source = replaceOnce(source, 'const pickNode = useCallback((cssX: number, cssY: number): null | SimNode => {', `const pickNode = useCallback((cssX: number, cssY: number): null | SimNode => {
    if (previewContains(previewRef.current, cssX, cssY)) return byIdRef.current.get(previewRef.current.id) ?? null;`);
      source = replaceOnce(source, 'setSelectedId(prev => (prev === drag.id ? null : drag.id))', 'setSelectedId(drag.id); inspectNode(drag.id)');
      return { contents: source, loader: 'tsx', resolveDir: path.dirname(args.path) };
    });
    plugin.onLoad({ filter: /starmap\/render\.ts$/ }, async args => {
      let source = await readFile(args.path, 'utf8');
      const start = source.indexOf('  if (tip) {\n');
      const end = source.indexOf('  // Neighbor constellation labels', start);
      if (start < 0 || end < start || source.indexOf('  if (tip) {\n', start + 1) >= 0) throw new Error('Hermes tooltip changed; review reader adapter');
      source = source.slice(0, start) + `  if (tip) {
    tipRect = drawMemoryPreview(ctx, tip, memById.get(tip.id), { w, h }, { x: projX(tip.x), y: projY(tip.y) }, darkTheme);
  }

` + source.slice(end);
      source = `import { drawMemoryPreview } from 'momo-memory-preview';\n` + source;
      source = replaceOnce(source, 'return { animating, ringLabelRects }', 'return { animating, ringLabelRects, previewHit: tipRect && tip ? { ...tipRect, id: tip.id } : null }');
      return { contents: source, loader: 'ts', resolveDir: path.dirname(args.path) };
    });
    plugin.onLoad({ filter: /starmap\/timeline\.tsx$/ }, async args => {
      let source = await readFile(args.path, 'utf8');
      source = replaceOnce(source, 'aria-label="Timeline scrubber"', `aria-label={/^zh\\b/i.test(navigator?.language || "zh") ? "记忆节点展开进度" : "Memory node reveal progress"} onKeyDown={e => {
        const d = e.key === 'ArrowRight' ? 0.05 : e.key === 'ArrowLeft' ? -0.05 : 0;
        if (d || e.key === 'Home' || e.key === 'End') { e.preventDefault(); e.stopPropagation(); onScrub(e.key === 'Home' ? 0 : e.key === 'End' ? 1 : Math.max(0, Math.min(1, revealStore.get() + d))); }
      }}`);
      source = source.replace("playing ? 'Pause' : 'Play timeline'", "playing ? (/^zh\\b/i.test(navigator?.language || 'zh') ? '暂停展开' : 'Pause') : (/^zh\\b/i.test(navigator?.language || 'zh') ? '展开记忆节点' : 'Expand memory nodes')");
      return { contents: source, loader: 'tsx', resolveDir: path.dirname(args.path) };
    });
  } }]
});
execFileSync(path.join(root, 'node_modules/.bin/tailwindcss'), ['-i', path.join(root, 'src/style.css'), '-o', path.join(out, 'memory.css'), '--minify'], { cwd: root, stdio: 'inherit' });
await copyFile(path.join(root, 'src/index.html'), path.join(out, 'index.html'));
await copyFile(path.resolve(upstream, '../../../LICENSE'), path.join(out, 'Hermes-LICENSE.txt'));
await writeFile(path.join(out, 'NOTICE.txt'), 'Memory StarMap rendering, simulation, timeline and gestures from Hermes Agent, Copyright (c) 2025 Nous Research, MIT. See Hermes-LICENSE.txt. MoMo adapter source: Apps/MacApp/MemoryUI.\n');
