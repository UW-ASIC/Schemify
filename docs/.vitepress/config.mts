import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Schemify',
  description: 'Open-source schematic editor — documentation',

  // GitHub Pages deployment path: https://<org>.github.io/Schemify/
  base: '/Schemify/',

  // Clean URLs (no .html suffix)
  cleanUrls: true,

  head: [
    // Inter for body, JetBrains Mono for code — matches zig-book's clean typography
    ['link', { rel: 'preconnect', href: 'https://fonts.googleapis.com' }],
    ['link', { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' }],
    ['link', {
      rel: 'stylesheet',
      href: 'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap'
    }],
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/Schemify/favicon.svg' }],
  ],

  themeConfig: {
    // ── Top navigation ──────────────────────────────────────────────────
    nav: [
      { text: 'Guide',      link: '/guide/getting-started',   activeMatch: '/guide/' },
      { text: 'Plugins',    link: '/plugins/overview',        activeMatch: '/plugins/' },
      { text: 'Themes',     link: '/themes',                  activeMatch: '/themes' },
      { text: 'Devices',    link: '/devices/overview',        activeMatch: '/devices/' },
      { text: 'Simulation', link: '/simulation/overview',     activeMatch: '/simulation/' },
    ],

    // ── Left sidebar ────────────────────────────────────────────────────
    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'What is Schemify?',   link: '/guide/introduction' },
          { text: 'Getting Started',     link: '/guide/getting-started' },
          { text: 'Config.toml',         link: '/guide/config' },
          { text: 'GitHub Pages',        link: '/guide/github-pages' },
        ],
      },
      {
        text: 'Plugins',
        items: [
          { text: 'Overview',            link: '/plugins/overview' },
          { text: 'Architecture',        link: '/plugins/architecture' },
          { text: 'API Reference',       link: '/plugins/api' },
        ],
      },
      {
        text: 'Creating Plugins',
        items: [
          { text: 'Quick Start',         link: '/plugins/creating/quick-start' },
          { text: 'Zig Plugin',          link: '/plugins/creating/zig' },
          { text: 'C Plugin',            link: '/plugins/creating/c' },
          { text: 'C++ Plugin',          link: '/plugins/creating/cpp' },
          { text: 'Rust Plugin',         link: '/plugins/creating/rust' },
          { text: 'Go Plugin',           link: '/plugins/creating/go' },
          { text: 'Python Plugin',       link: '/plugins/creating/python' },
          { text: 'WASM / Web Plugin',   link: '/plugins/creating/wasm' },
          { text: 'Publishing',          link: '/plugins/creating/publishing' },
        ],
      },
      {
        text: 'Using Plugins',
        items: [
          { text: 'Installing Plugins',  link: '/plugins/using/installing' },
          { text: 'Configuring Plugins', link: '/plugins/using/configuring' },
        ],
      },
      {
        text: 'Themes',
        items: [
          { text: 'Setting Themes',      link: '/themes' },
        ],
      },
      {
        text: 'Devices',
        items: [
          { text: 'Device System',       link: '/devices/overview' },
          { text: 'Custom Devices',      link: '/devices/custom-devices' },
        ],
      },
      {
        text: 'Simulation',
        items: [
          { text: 'Overview',            link: '/simulation/overview' },
          { text: 'Digital Blocks',      link: '/simulation/digital-blocks' },
        ],
      },
    ],

    // ── Footer links ────────────────────────────────────────────────────
    socialLinks: [
      { icon: 'github', link: 'https://github.com/UWASIC/Schemify' },
    ],

    editLink: {
      pattern: 'https://github.com/UWASIC/Schemify/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },


    // In-page table of contents depth (matches zig-book's right TOC)
    outline: { level: [2, 3], label: 'On this page' },

    search: { provider: 'local' },
  },

  markdown: {
    // Zig syntax highlighting is built into Shiki (VitePress's highlighter)
    theme: { light: 'github-light', dark: 'one-dark-pro' },
    lineNumbers: true,
  },
})
