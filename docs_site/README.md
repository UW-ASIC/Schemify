# Schemify Documentation Site

Static-first docs site for the Schemify schematic editor. Built with Bun + TypeScript, markdown content, SCSS styling, HTMX navigation.

## Stack

- **Server:** [Bun](https://bun.sh/) + TypeScript
- **Markdown:** `marked` + `marked-highlight` + `highlight.js`
- **Navigation:** HTMX (AJAX page loads without full reload)
- **Styling:** SCSS → CSS (same template as UWASIC Documentation)
- **Interactivity:** Vanilla JS (theme toggle, sidebar, scroll spy)

## Dev Setup

```bash
bun install
sass style/main.scss style/main.css   # compile SCSS once
bun run dev                            # start server on localhost:3000
```

## Content Structure

```
assets/content/
├── index.md                          # homepage
├── 1) Getting Started/               # numbered dirs → sidebar order
│   ├── introduction.md
│   ├── getting-started.md
│   ├── config.md
│   └── schemify-vs-xschem.md
├── 2) File Format/
│   ├── overview.md
│   ├── chn-format.md
│   └── device-kinds.md
├── 3) Usage/
│   ├── keyboard-shortcuts.md
│   └── components.md
├── 4) Developer Guide/
│   ├── architecture.md
│   ├── conventions.md
│   ├── build.md
│   └── testing.md
└── 5) Plugins/
    ├── overview.md
    ├── api.md
    └── building-plugins.md
```

Directory names prefixed with `N) ` are sorted numerically in the sidebar. The prefix is stripped from the displayed title.

## Adding Content

1. Create a `.md` file anywhere under `assets/content/`
2. Restart the server (or add hot-reload — PRs welcome)
3. The sidebar updates automatically from the directory scan

## SCSS Watch

```bash
sass --watch style/main.scss:style/main.css
```

## Static Build (for GitHub Pages)

```bash
bun run dev &
wget --mirror --convert-links --adjust-extension \
     --no-parent -P dist http://localhost:3000/
```

Set `SITE_URL=/Schemify` for subdirectory deployment.
