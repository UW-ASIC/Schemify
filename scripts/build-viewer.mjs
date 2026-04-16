#!/usr/bin/env node
/**
 * build-viewer.mjs
 *
 * Bundles a Schemify project directory + pre-built WASM assets into a
 * self-contained static site ready for GitHub Pages (or any static host).
 *
 * Usage (run from the project directory that contains Config.toml):
 *
 *   node build-viewer.mjs <schemify.wasm> <web.js> <output-dir>
 *
 * schemify_host.js, vfs.js, and vfs-worker.js are resolved automatically
 * from the same directory as web.js.
 *
 * Output layout:
 *
 *   <output-dir>/
 *     index.html       ← viewer shell
 *     boot.js          ← manifest-based VFS seeder + WASM boot
 *     schemify.wasm    ← Schemify WASM binary
 *     web.js           ← dvui JS runtime
 *     schemify_host.js ← Schemify host/VFS bridge
 *     vfs.js           ← in-page VFS map + OPFS worker launcher
 *     vfs-worker.js    ← OPFS persistence worker
 *     files.json       ← manifest of all project files
 *     <project files>  ← Config.toml + schematics, mirrored from cwd
 */

import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync, statSync, readdirSync } from 'fs';
import { join, relative, resolve, dirname, basename } from 'path';

// ── CLI args ──────────────────────────────────────────────────────────────────

const [wasmSrc, webJsSrc, outDir] = process.argv.slice(2);

if (!wasmSrc || !webJsSrc || !outDir) {
  console.error('Usage: node build-viewer.mjs <schemify.wasm> <web.js> <output-dir>');
  process.exit(1);
}

const assetsDir    = dirname(resolve(webJsSrc));
const hostJsSrc    = join(assetsDir, 'schemify_host.js');
const vfsSrc       = join(assetsDir, 'vfs.js');
const vfsWorkerSrc = join(assetsDir, 'vfs-worker.js');

for (const [label, p] of [
  ['schemify.wasm',    wasmSrc],
  ['web.js',           webJsSrc],
  ['schemify_host.js', hostJsSrc],
  ['vfs.js',           vfsSrc],
  ['vfs-worker.js',    vfsWorkerSrc],
]) {
  if (!existsSync(p)) {
    console.error(`Missing required asset: ${label} (looked at ${p})`);
    process.exit(1);
  }
}

const projectDir = process.cwd();

// ── Helpers ───────────────────────────────────────────────────────────────────

function ensureDir(p) {
  mkdirSync(p, { recursive: true });
}

function copyFile(src, dest) {
  ensureDir(dirname(dest));
  copyFileSync(src, dest);
}

/** Recursively collect all files under `dir`, returning paths relative to `dir`. */
function collectFiles(dir, base = dir) {
  const results = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...collectFiles(full, base));
    } else {
      results.push(relative(base, full));
    }
  }
  return results;
}

// ── Read Config.toml for project name ─────────────────────────────────────────

let projectName = 'Schemify Project';
const configPath = join(projectDir, 'Config.toml');
if (existsSync(configPath)) {
  const toml = readFileSync(configPath, 'utf8');
  const m = toml.match(/^\s*name\s*=\s*"([^"]+)"/m);
  if (m) projectName = m[1];
}

// ── Collect project files ─────────────────────────────────────────────────────

const SCHEMATIC_EXTS = new Set([
  '.chn', '.chn_tb', '.chn_prim',
  '.sch', '.sym',
  '.cir', '.spice', '.sp',
  '.toml',
]);

const allFiles = collectFiles(projectDir).filter(f =>
  [...SCHEMATIC_EXTS].some(e => f.endsWith(e))
);

console.log(`Found ${allFiles.length} project file(s) in ${projectDir}`);
allFiles.forEach(f => console.log('  +', f));

// ── Build output directory ────────────────────────────────────────────────────

ensureDir(outDir);

// Copy WASM + JS runtime assets
copyFile(wasmSrc,    join(outDir, 'schemify.wasm'));
copyFile(webJsSrc,   join(outDir, 'web.js'));
copyFile(hostJsSrc,  join(outDir, 'schemify_host.js'));
copyFile(vfsSrc,     join(outDir, 'vfs.js'));
copyFile(vfsWorkerSrc, join(outDir, 'vfs-worker.js'));

// Mirror project files
for (const f of allFiles) {
  copyFile(join(projectDir, f), join(outDir, f));
}

// Write manifest
const manifest = { project: projectName, files: allFiles };
writeFileSync(join(outDir, 'files.json'), JSON.stringify(manifest, null, 2));

// ── Generate boot.js ──────────────────────────────────────────────────────────

const bootJs = `import { Dvui } from "./web.js";

const vfs = window.SchemifyVFS;

function setMsg(text) {
  const el = document.getElementById('loading-msg');
  if (el) el.textContent = text;
}

await vfs.init();

setMsg('Fetching project manifest\\u2026');
const manifest = await fetch('files.json').then(r => r.json()).catch(() => ({ files: [] }));

let loaded = 0;
await Promise.all(manifest.files.map(async path => {
  try {
    const res = await fetch(path);
    if (!res.ok) return;
    const data = new Uint8Array(await res.arrayBuffer());
    vfs.files.set(path, data);
    vfs.markDirty(path);
    setMsg(\`Loading files\\u2026 \${++loaded}/\${manifest.files.length}\`);
  } catch (_) {}
}));

setMsg('Starting Schemify\\u2026');

const app = new Dvui();
const importObject = {
  dvui: app.imports,
  host: window.SchemifyHost.imports,
};

const result = await WebAssembly.instantiateStreaming(fetch('schemify.wasm'), importObject);
window.SchemifyHost.setMemory(result.instance.exports.memory);
app.setInstance(result.instance);
app.setCanvas('#dvui-canvas');

const loadingEl = document.getElementById('loading');
if (loadingEl) loadingEl.remove();

app.run();
`;

writeFileSync(join(outDir, 'boot.js'), bootJs);

// ── Generate index.html ───────────────────────────────────────────────────────

const html = `<!DOCTYPE html>
<html lang="en" style="height:100%">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>${escHtml(projectName)} \u2014 Schemify</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    html, body { width: 100%; height: 100%; background: #0d1117; overflow: hidden; }
    #dvui-canvas {
      display: block; width: 100%; height: 100%;
      outline: none; caret-color: transparent;
    }
    #loading {
      position: fixed; inset: 0; display: flex; flex-direction: column;
      align-items: center; justify-content: center; gap: 12px;
      background: #0d1117; color: #4ec9b0;
      font-size: 14px; font-family: ui-monospace, monospace; z-index: 10;
    }
    .spinner {
      width: 36px; height: 36px;
      border: 3px solid #1e3a4a; border-top-color: #4ec9b0;
      border-radius: 50%; animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div id="loading">
    <div class="spinner"></div>
    <span id="loading-msg">Loading ${escHtml(projectName)}\u2026</span>
  </div>
  <canvas id="dvui-canvas" tabIndex="1"></canvas>

  <!-- Order matters: vfs \u2192 host \u2192 boot -->
  <script src="vfs.js"></script>
  <script src="schemify_host.js"></script>
  <script type="module" src="boot.js"></script>
</body>
</html>`;

writeFileSync(join(outDir, 'index.html'), html);

console.log(`\nViewer written to: ${resolve(outDir)}`);
console.log(`  index.html`);
console.log(`  boot.js`);
console.log(`  schemify.wasm`);
console.log(`  web.js`);
console.log(`  schemify_host.js`);
console.log(`  vfs.js`);
console.log(`  vfs-worker.js`);
console.log(`  files.json   (${allFiles.length} files)`);

// ── Util ──────────────────────────────────────────────────────────────────────

function escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
