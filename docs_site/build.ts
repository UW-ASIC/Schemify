import { marked } from "marked";
import { markedHighlight } from "marked-highlight";
import hljs from "highlight.js";
import {
  readFileSync,
  readdirSync,
  statSync,
  existsSync,
  mkdirSync,
  writeFileSync,
  copyFileSync,
} from "fs";
import { join, extname, basename, relative } from "path";

// ── marked setup (identical to server.ts) ────────────────────────────────────
marked.use(
  markedHighlight({
    langPrefix: "hljs language-",
    highlight(code, lang) {
      const language = hljs.getLanguage(lang) ? lang : "plaintext";
      return hljs.highlight(code, { language }).value;
    },
  })
);

const CONTENT_DIR = join(import.meta.dir, "assets/content");
const STYLE_DIR   = join(import.meta.dir, "style");
const PUBLIC_DIR  = join(import.meta.dir, "public");
const OUT_DIR     = join(import.meta.dir, "dist");

// ── helpers (shared with server.ts) ──────────────────────────────────────────
interface SidebarItem {
  title: string;
  path: string;
  children: SidebarItem[];
}

function parseNumberedName(name: string): [number, string] {
  const match = name.match(/^(\d+)\)\s*(.*)/);
  if (match) return [parseInt(match[1]), match[2].trim()];
  return [Infinity, name];
}

function formatTitle(s: string): string {
  const [, clean] = parseNumberedName(s);
  const name = clean || s;
  const stem = name.replace(/\.(md)$/, "");
  return stem
    .split(/[-_]/)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

function scanDir(dir: string, urlPrefix: string): SidebarItem[] {
  let entries: Array<{ sortKey: number; cleanName: string; originalName: string; fullPath: string }> = [];
  try {
    const names = readdirSync(dir);
    for (const name of names) {
      if (name === "images" || name.startsWith(".")) continue;
      const [sortKey, cleanName] = parseNumberedName(name);
      entries.push({ sortKey, cleanName, originalName: name, fullPath: join(dir, name) });
    }
  } catch { return []; }

  entries.sort((a, b) => a.sortKey - b.sortKey);

  const items: SidebarItem[] = [];
  for (const { cleanName, originalName, fullPath } of entries) {
    const displayName = cleanName || originalName;
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      const itemUrl = `${urlPrefix}/${originalName}`;
      items.push({ title: formatTitle(displayName), path: itemUrl, children: scanDir(fullPath, itemUrl) });
    } else if (extname(originalName) === ".md") {
      const stem = basename(originalName, ".md");
      items.push({ title: formatTitle(stem), path: `${urlPrefix}/${stem}`, children: [] });
    }
  }
  return items;
}

function generateSidebar(): SidebarItem[] {
  const categories: SidebarItem[] = [];
  let tops: Array<{ sortKey: number; cleanName: string; originalName: string; fullPath: string }> = [];
  try {
    const names = readdirSync(CONTENT_DIR);
    for (const name of names) {
      if (name === "images" || name.startsWith(".")) continue;
      const fullPath = join(CONTENT_DIR, name);
      if (!statSync(fullPath).isDirectory()) continue;
      const [sortKey, cleanName] = parseNumberedName(name);
      tops.push({ sortKey, cleanName, originalName: name, fullPath });
    }
  } catch { return []; }

  tops.sort((a, b) => a.sortKey - b.sortKey);

  for (const { cleanName, originalName, fullPath } of tops) {
    const displayName = cleanName || originalName;
    const urlPrefix = `/${originalName}`;
    categories.push({ title: formatTitle(displayName), path: urlPrefix, children: scanDir(fullPath, urlPrefix) });
  }
  return categories;
}

function renderSidebarItem(item: SidebarItem, activePath: string, depth = 0): string {
  const isActive = activePath === item.path || activePath.startsWith(item.path + "/");
  if (item.children.length === 0) {
    return `<a href="${item.path}" class="topic-link ${activePath === item.path ? "active" : ""}">${item.title}</a>`;
  }
  if (depth === 0) {
    return `
<div class="category">
  <details class="category-dropdown" ${isActive ? "open" : ""}>
    <summary class="category-link ${isActive ? "active" : ""}">${item.title}</summary>
    <div class="chapters">
      ${item.children.map((c) => renderSidebarItem(c, activePath, depth + 1)).join("\n")}
    </div>
  </details>
</div>`;
  }
  return `
<details class="chapter-dropdown" ${isActive ? "open" : ""}>
  <summary class="chapter-link"><span class="arrow">▶</span>${item.title}</summary>
  <div class="topics">
    ${item.children.map((c) => renderSidebarItem(c, activePath, depth + 1)).join("\n")}
  </div>
</details>`;
}

function renderSidebar(activePath: string): string {
  const items = generateSidebar();
  return `
<aside class="sidebar">
  <button class="sidebar-toggle" title="Toggle Sidebar">
    <span></span><span></span><span></span>
  </button>
  <nav>
    ${items.map((item) => renderSidebarItem(item, activePath)).join("\n")}
  </nav>
</aside>`;
}

function renderLayout(options: { title: string; pageTitle: string; sidebar: string; content: string; depth: number }): string {
  const root = options.depth === 0 ? "." : Array(options.depth).fill("..").join("/");
  return `<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${options.title}</title>
  <link rel="stylesheet" href="${root}/style/main.css" />
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css" />
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css" crossorigin="anonymous">
  <script src="${root}/public/app.js" defer></script>
</head>
<body>
  <div class="topbar">
    <div class="left">
      <a href="/" class="site-title">Schemify</a>
    </div>
    <div class="center" id="topbar-center">${options.pageTitle}</div>
    <div class="right">
      <button class="theme-toggle" title="Switch Theme">🌗</button>
    </div>
  </div>

  <div id="app">
    ${options.sidebar}
    <main class="content">
      <div id="page-content" class="markdown-body">
        ${options.content}
      </div>
    </main>
  </div>
</body>
</html>`;
}

// ── static file copy helper ───────────────────────────────────────────────────
function copyDir(src: string, dest: string) {
  mkdirSync(dest, { recursive: true });
  for (const name of readdirSync(src)) {
    const s = join(src, name);
    const d = join(dest, name);
    if (statSync(s).isDirectory()) copyDir(s, d);
    else copyFileSync(s, d);
  }
}

// ── collect all markdown pages ────────────────────────────────────────────────
interface Page {
  mdPath: string;   // absolute path to .md file
  urlPath: string;  // e.g. "/1) Getting Started/introduction"
}

function collectPages(dir: string, urlPrefix: string, out: Page[]) {
  for (const name of readdirSync(dir).sort()) {
    if (name.startsWith(".")) continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      collectPages(full, `${urlPrefix}/${name}`, out);
    } else if (extname(name) === ".md") {
      const stem = basename(name, ".md");
      out.push({
        mdPath: full,
        urlPath: stem === "index" ? urlPrefix || "/" : `${urlPrefix}/${stem}`,
      });
    }
  }
}

// ── main build ────────────────────────────────────────────────────────────────
async function build() {
  mkdirSync(OUT_DIR, { recursive: true });

  // Copy static assets
  copyDir(STYLE_DIR, join(OUT_DIR, "style"));
  copyDir(PUBLIC_DIR, join(OUT_DIR, "public"));

  // Collect all pages
  const pages: Page[] = [];

  // Homepage
  const indexMd = join(CONTENT_DIR, "index.md");
  if (existsSync(indexMd)) pages.push({ mdPath: indexMd, urlPath: "/" });

  // All content pages
  collectPages(CONTENT_DIR, "", pages);

  // Prevent Jekyll from processing the output (required for dirs with special chars)
  writeFileSync(join(OUT_DIR, ".nojekyll"), "");

  let built = 0;
  for (const { mdPath, urlPath } of pages) {
    const md = readFileSync(mdPath, "utf-8");
    const content = await marked(md);
    const pageTitle = urlPath === "/" ? "Schemify Documentation" : formatTitle(basename(mdPath, ".md"));
    const sidebar = renderSidebar(urlPath);

    // Determine output path and depth (for relative asset refs)
    let outFile: string;
    let depth: number;
    if (urlPath === "/") {
      outFile = join(OUT_DIR, "index.html");
      depth = 0;
    } else {
      const parts = urlPath.split("/").filter(Boolean);
      depth = parts.length;
      const outDir = join(OUT_DIR, ...parts);
      mkdirSync(outDir, { recursive: true });
      outFile = join(outDir, "index.html");
    }

    const html = renderLayout({
      title: `${pageTitle} — Schemify Docs`,
      pageTitle,
      sidebar,
      content,
      depth,
    });

    writeFileSync(outFile, html);
    built++;
  }

  console.log(`Built ${built} pages → ${relative(process.cwd(), OUT_DIR)}/`);
}

build().catch((e) => { console.error(e); process.exit(1); });
