---
id: gui/07
title: Wire disabled menu items (Export SVG, Highlight Nets)
status: ready-for-agent
priority: low
labels: [gui-linking, display]
---

# Wire disabled menu items

## Problem

Several menu items in `chrome.rs` permanently disabled:
- Export SVG
- Highlight Selected Nets
- Unhighlight All
- Edit in New Tab

## Acceptance criteria

- [ ] Export SVG: implement SVG export or remove menu item
- [ ] Highlight nets: wire to selection-based net highlighting
- [ ] Unhighlight All: clear all net highlights
- [ ] Edit in New Tab: open selected instance's symbol in new tab
- [ ] If feature not ready, add `(coming soon)` suffix instead of silent disable
