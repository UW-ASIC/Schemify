# Tabs and Files

Working with multiple files, tabs, and the file explorer.

---

## Tabs

Schemify uses a tabbed interface. Each tab holds one schematic document.

| Action | Key | Menu |
| --- | --- | --- |
| New tab | Ctrl+T | File > New Tab |
| Close tab | Ctrl+W | File > Close Tab |
| Next tab | Ctrl+Right | — |
| Previous tab | Ctrl+Left | — |
| Reopen closed tab | Ctrl+Shift+T | File > Reopen Closed Tab |

### Tab Bar

The tab bar sits between the toolbar and the canvas:
- Click a tab name to switch
- Click **x** to close (only shown when multiple tabs are open)
- Click **+** to create a new tab
- Dirty (unsaved) tabs show a `*` prefix

### SCH / SYM Toggle

On the right side of the tab bar are **SCH** and **SYM** buttons to switch between schematic view and symbol view for the current document.

---

## File Operations

| Action | Key | Menu |
| --- | --- | --- |
| New schematic | Ctrl+N | File > New Schematic |
| Open file | Ctrl+O | File > Open |
| Save | Ctrl+S | File > Save |
| Save as | — | File > Save As |
| Save all | — | File > Save All |
| Reload from disk | Alt+S | File > Reload from Disk |

### Recent Files

The **File** menu shows recently opened files at the bottom. Click to reopen.

---

## File Explorer

Press **Ctrl+Shift+E** or go to **View > File Explorer** to toggle the file explorer panel.

The file explorer shows the directory tree of the current working directory. Click files to open them.

---

## Supported File Types

| Extension | Description |
| --- | --- |
| `.chn` | Schemify schematic |
| `.chn_prim` | Primitive symbol definition |
| `.chn_tb` | Testbench schematic |
| `.comp` | Internal buffer name (unsaved) |

All file types are plain text and can be version-controlled with Git.
