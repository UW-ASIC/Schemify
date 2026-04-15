import { marked } from "marked";
import { markedHighlight } from "marked-highlight";
import hljs from "highlight.js";
import { readFileSync, readdirSync, statSync, existsSync } from "fs";
import { join, extname, basename, dirname } from "path";

// Configure marked with syntax highlighting
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
const STYLE_DIR = join(import.meta.dir, "style");
const ASSETS_DIR = join(import.meta.dir, "assets");
const JS_DIR = join(import.meta.dir, "public");

interface SidebarItem {
  title: string;
  path: string;
  children: SidebarItem[];
}

function parseNumberedName(name: string): [number, string] {
  const match = name.match(/^(\d+)\)\s*(.*)/);
  if (match) {
    return [parseInt(match[1]), match[2].trim()];
  }
  return [Infinity, name];
}

function formatTitle(s: string): string {
  const [, clean] = parseNumberedName(s);
  const name = clean || s;
  // Remove extension if present
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
  } catch {
    return [];
  }

  entries.sort((a, b) => a.sortKey - b.sortKey);

  const items: SidebarItem[] = [];
  for (const { cleanName, originalName, fullPath } of entries) {
    const displayName = cleanName || originalName;
    const stat = statSync(fullPath);

    if (stat.isDirectory()) {
      const itemUrl = `${urlPrefix}/${originalName}`;
      const children = scanDir(fullPath, itemUrl);
      items.push({
        title: formatTitle(displayName),
        path: itemUrl,
        children,
      });
    } else if (extname(originalName) === ".md") {
      const stem = basename(originalName, ".md");
      const fileUrl = `${urlPrefix}/${stem}`;
      items.push({
        title: formatTitle(stem),
        path: fileUrl,
        children: [],
      });
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
  } catch {
    return [];
  }

  tops.sort((a, b) => a.sortKey - b.sortKey);

  for (const { cleanName, originalName, fullPath } of tops) {
    const displayName = cleanName || originalName;
    const urlPrefix = `/${originalName}`;
    const children = scanDir(fullPath, urlPrefix);
    categories.push({
      title: formatTitle(displayName),
      path: urlPrefix,
      children,
    });
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
  const itemsHtml = items.map((item) => renderSidebarItem(item, activePath)).join("\n");

  return `
<aside class="sidebar" hx-boost="true" hx-target="#app" hx-select="#app">
  <button class="sidebar-toggle" title="Toggle Sidebar">
    <span></span><span></span><span></span>
  </button>
  <nav>
    ${itemsHtml}
  </nav>
</aside>`;
}

function renderLayout(options: {
  title: string;
  pageTitle: string;
  sidebar: string;
  content: string;
}): string {
  return `<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${options.title}</title>
  <link rel="stylesheet" href="/style/main.css" />
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css" />
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css" crossorigin="anonymous">
  <script src="https://unpkg.com/htmx.org@1.9.10"></script>
  <script src="/public/app.js" defer></script>
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

async function renderMarkdownPage(filePath: string, activePath: string, pageTitle: string): Promise<string | null> {
  try {
    const md = readFileSync(filePath, "utf-8");
    const content = await marked(md);
    const sidebar = renderSidebar(activePath);
    return renderLayout({
      title: `${pageTitle} — Schemify Docs`,
      pageTitle,
      sidebar,
      content,
    });
  } catch {
    return null;
  }
}

const server = Bun.serve({
  port: 3000,
  async fetch(req) {
    const url = new URL(req.url);
    let pathname = url.pathname;

    // Serve static files
    if (pathname.startsWith("/style/")) {
      const file = join(STYLE_DIR, pathname.replace("/style/", ""));
      if (existsSync(file)) return new Response(Bun.file(file));
    }

    if (pathname.startsWith("/assets/")) {
      const file = join(ASSETS_DIR, pathname.replace("/assets/", ""));
      if (existsSync(file)) return new Response(Bun.file(file));
    }

    if (pathname.startsWith("/public/")) {
      const file = join(JS_DIR, pathname.replace("/public/", ""));
      if (existsSync(file)) return new Response(Bun.file(file));
    }

    // Index
    if (pathname === "/") {
      const html = await renderMarkdownPage(
        join(CONTENT_DIR, "index.md"),
        "/",
        "Schemify Documentation"
      );
      if (html) return new Response(html, { headers: { "Content-Type": "text/html" } });
    }

    // Dynamic content pages
    const segments = pathname.split("/").filter(Boolean);
    const mdPath = join(CONTENT_DIR, ...segments) + ".md";
    const pageTitle = formatTitle(segments[segments.length - 1] || "index");

    if (existsSync(mdPath)) {
      const html = await renderMarkdownPage(mdPath, pathname, pageTitle);
      if (html) return new Response(html, { headers: { "Content-Type": "text/html" } });
    }

    // Try index.md in directory
    const dirIndexPath = join(CONTENT_DIR, ...segments, "index.md");
    if (existsSync(dirIndexPath)) {
      const html = await renderMarkdownPage(dirIndexPath, pathname, pageTitle);
      if (html) return new Response(html, { headers: { "Content-Type": "text/html" } });
    }

    return new Response("<h1>404 Not Found</h1>", {
      status: 404,
      headers: { "Content-Type": "text/html" },
    });
  },
});

console.log(`Schemify docs running at http://localhost:${server.port}`);
