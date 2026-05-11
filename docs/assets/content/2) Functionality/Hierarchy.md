# Hierarchy

How to work with hierarchical designs — subcircuits, push/pop navigation, and symbol/schematic generation.

---

## Navigation

Schemify supports hierarchical designs. You can place instances that reference other schematics and navigate through the hierarchy.

| Action | Key | Menu |
| --- | --- | --- |
| Descend into schematic | E | Hierarchy > Descend into Schematic |
| Descend into symbol | I | Hierarchy > Descend into Symbol |
| Ascend to parent | Backspace or Ctrl+E | Hierarchy > Go Up / Ascend |
| Edit in new tab | Alt+I or Alt+E | Hierarchy > Edit in New Tab |

### How It Works

1. Select an instance
2. Press **E** to descend — the child schematic opens and becomes the active view
3. The status bar shows a breadcrumb trail: `parent > child > grandchild`
4. Press **Backspace** to go back up

Descending pushes the current document onto the hierarchy stack. Ascending pops it.

---

## Symbol Generation

### Make Symbol from Schematic (A)

Press **A** to auto-generate a symbol from the current schematic's pin instances.

1. Place `ipin`, `opin`, and `iopin` instances in your schematic
2. Press **A**
3. Schemify generates a symbol with:
   - A bounding rectangle
   - Input pins on the left
   - Output pins on the right
   - Bidirectional pins on the bottom
   - The cell name as a label

### Make Schematic from Symbol (Ctrl+L)

Press **Ctrl+L** to generate a schematic stub from the current symbol's pin list. Each pin becomes an `ipin`, `opin`, or `iopin` instance placed in a column layout.

Both operations are available from **Hierarchy** menu.

---

## File Types

| Extension | Purpose |
| --- | --- |
| `.chn` | Schematic (instances + wires) |
| `.chn_prim` | Primitive symbol definition |
| `.chn_tb` | Testbench schematic |

When descending (E), Schemify looks for `.chn` files. When descending into symbol (I), it looks for `.chn_prim` files. Symbol resolution searches the working directory and configured library paths.

---

## Merging Files

Press **B** or use **File > Merge external file** to import an external `.chn` file into the current schematic.

- Imported instances are offset to the cursor position
- Name collisions are resolved by appending `_imp` suffix
- Wires are imported with the same offset
