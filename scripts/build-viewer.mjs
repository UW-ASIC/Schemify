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
 * Output layout:
 *
 *   <output-dir>/
 *     index.html       ← viewer shell + VFS loader
 *     schemify.wasm    ← Schemify WASM binary
 *     web.js           ← Schemify JS glue
 *     files.json       ← manifest of all project files
 *     <project files>  ← Config.toml + schematics, mirrored from cwd
 */

import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync, statSync, readdirSync } from 'fs';
import { join, relative, resolve, dirname, basename } from 'path';
import { fileURLToPath } from 'url';

// ── CLI args ──────────────────────────────────────────────────────────────────

const [wasmSrc, webJsSrc, outDir] = process.argv.slice(2);

if (!wasmSrc || !webJsSrc || !outDir) {
  console.error('Usage: node build-viewer.mjs <schemify.wasm> <web.js> <output-dir>');
  process.exit(1);
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
    if (entry.name.startsWith('.')) continue;          // skip hidden / temp dirs
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

/** Extensions recognised as schematic/project files. */
const SCHEMATIC_EXTS = new Set([
  '.chn', '.chn_tb', '.chn_prim',
  '.sch', '.sym',
  '.cir', '.spice', '.sp',
  '.toml',
]);

const allFiles = collectFiles(projectDir).filter(f => {
  const ext = '.' + f.split('.').slice(1).join('.');   // handles multi-dot exts
  // accept if any known ext is a suffix of the file path
  return [...SCHEMATIC_EXTS].some(e => f.endsWith(e));
});

console.log(`Found ${allFiles.length} project file(s) in ${projectDir}`);
allFiles.forEach(f => console.log('  +', f));

// ── Build output directory ────────────────────────────────────────────────────

ensureDir(outDir);

// Copy WASM + JS runtime
copyFile(wasmSrc,  join(outDir, 'schemify.wasm'));
copyFile(webJsSrc, join(outDir, 'web.js'));

// Mirror project files
for (const f of allFiles) {
  copyFile(join(projectDir, f), join(outDir, f));
}

// Write manifest
const manifest = { project: projectName, files: allFiles };
writeFileSync(join(outDir, 'files.json'), JSON.stringify(manifest, null, 2));

// ── Generate index.html ───────────────────────────────────────────────────────

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>${escHtml(projectName)} — Schemify</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body { width: 100%; height: 100%; background: #0d1117; color: #e6edf3; font-family: monospace; }
    #schemify-canvas { display: block; width: 100%; height: 100vh; }
    #loading {
      position: fixed; inset: 0; display: flex; flex-direction: column;
      align-items: center; justify-content: center; gap: 12px;
      background: #0d1117; color: #4ec9b0; font-size: 14px; z-index: 10;
    }
    #loading.hidden { display: none; }
    .spinner {
      width: 36px; height: 36px; border: 3px solid #1e3a4a;
      border-top-color: #4ec9b0; border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div id="loading">
    <div class="spinner"></div>
    <span id="loading-msg">Loading ${escHtml(projectName)}…</span>
  </div>
  <canvas id="schemify-canvas"></canvas>

  <script type="module">
    // ── In-memory VFS ─────────────────────────────────────────────────────────
    // Implements the six host functions that Schemify's Vfs.zig calls via WASM
    // imports.  Files are pre-loaded from the static manifest before WASM boots.

    const vfs = new Map();           // path → Uint8Array
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    function wasmStr(mem, ptr, len) {
      return decoder.decode(new Uint8Array(mem.buffer, ptr, len));
    }
    function wasmWrite(mem, dest, src, maxLen) {
      const bytes = src instanceof Uint8Array ? src : encoder.encode(src);
      const n = Math.min(bytes.length, maxLen);
      new Uint8Array(mem.buffer, dest, n).set(bytes.subarray(0, n));
      return n;
    }

    function makeHostImports(getMemory) {
      return {
        vfs_file_len(pathPtr, pathLen) {
          const path = wasmStr(getMemory(), pathPtr, pathLen);
          const f = vfs.get(path);
          return f ? f.byteLength : -1;
        },
        vfs_file_read(pathPtr, pathLen, dest, destLen) {
          const mem = getMemory();
          const path = wasmStr(mem, pathPtr, pathLen);
          const f = vfs.get(path);
          if (!f) return -1;
          return wasmWrite(mem, dest, f, destLen);
        },
        vfs_file_write(pathPtr, pathLen, src, srcLen) {
          const mem = getMemory();
          const path = wasmStr(mem, pathPtr, pathLen);
          const data = new Uint8Array(mem.buffer, src, srcLen).slice();
          vfs.set(path, data);
          return 0;
        },
        vfs_dir_make(pathPtr, pathLen) {
          // Directories are implicit in the flat Map — nothing to do.
          return 0;
        },
        vfs_dir_list_len(pathPtr, pathLen) {
          const mem = getMemory();
          const prefix = wasmStr(mem, pathPtr, pathLen).replace(/\\/?$/, '/');
          const entries = [...vfs.keys()]
            .filter(k => k.startsWith(prefix))
            .map(k => k.slice(prefix.length).split('/')[0])
            .filter((v, i, a) => v && a.indexOf(v) === i);
          if (entries.length === 0) return -1;
          return entries.reduce((s, e) => s + encoder.encode(e).length + 1, 0);
        },
        vfs_dir_list_read(pathPtr, pathLen, dest, destLen) {
          const mem = getMemory();
          const prefix = wasmStr(mem, pathPtr, pathLen).replace(/\\/?$/, '/');
          const entries = [...vfs.keys()]
            .filter(k => k.startsWith(prefix))
            .map(k => k.slice(prefix.length).split('/')[0])
            .filter((v, i, a) => v && a.indexOf(v) === i);
          const nulSep = encoder.encode(entries.join('\\0') + '\\0');
          return wasmWrite(mem, dest, nulSep, destLen);
        },
      };
    }

    // ── Load project files into VFS ───────────────────────────────────────────

    const msg = document.getElementById('loading-msg');
    msg.textContent = 'Fetching project manifest…';

    const manifest = await fetch('files.json').then(r => r.json());
    let loaded = 0;
    await Promise.all(manifest.files.map(async path => {
      const res = await fetch(path);
      if (!res.ok) { console.warn('VFS: could not fetch', path); return; }
      const buf = new Uint8Array(await res.arrayBuffer());
      vfs.set(path, buf);
      // Also register under bare filename for flat-open compat
      const base = path.split('/').pop();
      if (base !== path) vfs.set(base, buf);
      msg.textContent = \`Loading files… \${++loaded}/\${manifest.files.length}\`;
    }));

    // ── Boot WASM ─────────────────────────────────────────────────────────────

    msg.textContent = 'Starting Schemify…';

    // web.js is generated by \`zig build -Dbackend=web\`.
    // It expects \`window.SCHEMIFY_IMPORTS\` to be set before it runs so the
    // module instantiation can pick up the host VFS functions.
    let wasmMemory = null;
    const getMemory = () => wasmMemory;

    window.SCHEMIFY_CANVAS  = document.getElementById('schemify-canvas');
    window.SCHEMIFY_IMPORTS = { host: makeHostImports(getMemory) };
    window.SCHEMIFY_ON_MEMORY = (mem) => { wasmMemory = mem; };

    const { default: initSchemify } = await import('./web.js');
    await initSchemify({ wasmPath: 'schemify.wasm' });

    document.getElementById('loading').classList.add('hidden');
  </script>
</body>
</html>`;

writeFileSync(join(outDir, 'index.html'), html);

console.log(`\nViewer written to: ${resolve(outDir)}`);
console.log(`  index.html   (${(html.length / 1024).toFixed(1)} kB)`);
console.log(`  schemify.wasm`);
console.log(`  web.js`);
console.log(`  files.json   (${allFiles.length} files)`);

// ── Util ──────────────────────────────────────────────────────────────────────

function escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
