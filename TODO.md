# Schemify GUI Manual Test Checklist

Test every feature below. Check the box when it works. If something is broken, write what happened next to it.

---

## 1. Application Startup

- [ ] App opens without crashing when you run `zig build run`
- [ ] You see a canvas (big drawing area) in the middle of the screen
- [ ] You see a menu bar at the top (File, Edit, Insert, View, Simulate, Plugins)
- [ ] You see a tab bar below the menu (showing at least one tab)
- [ ] You see a status/command bar at the very bottom
- [ ] The grid (dots or lines pattern) is visible on the canvas

---

## 2. File Menu

- [ ] **New File (Ctrl+N):** Creates a fresh empty schematic — canvas clears out
- [ ] **Open File (Ctrl+O):** Opens a file picker — you can choose a `.chn` file and it loads onto the canvas
- [ ] **Save (Ctrl+S):** Saves the current schematic — no error message appears in status bar
- [ ] **Save As (Ctrl+Shift+S):** Opens a "save as" dialog — you can pick a new filename
- [ ] **Reload from Disk (Alt+S):** Reloads the file from disk — any unsaved changes disappear
- [ ] **Clear Schematic:** Clears everything on the canvas — it becomes empty
- [ ] **Start New Process (Ctrl+Shift+N):** Opens a second Schemify window
- [ ] **View Logs (Ctrl+L):** Shows a log/debug window
- [ ] **Exit (Ctrl+Q):** Closes the application

---

## 3. Tab Management

- [ ] **New Tab (Ctrl+T):** A new tab appears in the tab bar — canvas shows an empty schematic
- [ ] **Close Tab (Ctrl+W):** The current tab disappears — switches to another tab (only works if more than one tab is open)
- [ ] **Next Tab (Ctrl+Right):** Switches to the tab on the right
- [ ] **Previous Tab (Ctrl+Left):** Switches to the tab on the left
- [ ] **Reopen Last Closed Tab (Ctrl+Shift+T):** Brings back the last tab you closed
- [ ] **Click a Tab:** Clicking on a tab switches to that schematic
- [ ] **Dirty Indicator:** If you make changes without saving, the tab shows a dot or marker to say "unsaved"
- [ ] **SCH / SYM Toggle:** You see SCH and SYM buttons near the tabs — clicking SCH shows schematic view, clicking SYM shows symbol view

---

## 4. Canvas Navigation (Moving Around the Drawing)

- [ ] **Scroll Wheel Zoom:** Roll the mouse wheel up to zoom in, down to zoom out — zoom follows where your cursor is
- [ ] **Pan with Middle Mouse:** Hold middle mouse button and drag — the canvas moves around
- [ ] **Pan with Space + Left Click:** Hold spacebar, then click and drag — the canvas moves around
- [ ] **Space Tap Pan Mode:** Tap spacebar quickly — now just moving the mouse pans the canvas. Click to exit this mode
- [ ] **Zoom In (Ctrl+=):** Canvas zooms in, things get bigger
- [ ] **Zoom Out (Ctrl+-):** Canvas zooms out, things get smaller
- [ ] **Zoom Fit (F or Z):** Canvas zooms and pans so everything fits on screen
- [ ] **Zoom 100% (Ctrl+0):** Canvas resets to the default zoom level
- [ ] **Zoom Fit Selection (Ctrl+Shift+F):** If you have something selected, the view zooms to show just that selection
- [ ] **Toggle Fullscreen (Backslash \\):** The app goes fullscreen — press again to go back to windowed

---

## 5. Selecting Things

- [ ] **Click to Select:** Click on a component (like a resistor) — it gets highlighted/selected
- [ ] **Click Empty to Deselect:** Click on empty canvas — everything gets deselected
- [ ] **Rubber-Band Select:** Click and drag on empty canvas — a selection rectangle appears. Everything inside it gets selected when you release
- [ ] **Select All (Ctrl+A):** Every component and wire on the canvas becomes selected
- [ ] **Select None (Ctrl+Shift+A):** Everything gets deselected
- [ ] **Find/Select (Ctrl+F):** A search dialog opens — you can type to search for components

---

## 6. Placing Components (Insert Menu)

### Primitives (Insert → submenu)
- [ ] **NMOS:** Click to place an NMOS transistor on the canvas
- [ ] **PMOS:** Click to place a PMOS transistor on the canvas
- [ ] **Resistor:** Click to place a resistor
- [ ] **Capacitor:** Click to place a capacitor
- [ ] **Inductor:** Click to place an inductor
- [ ] **Diode:** Click to place a diode
- [ ] **Voltage Source:** Click to place a voltage source (circle with + and -)
- [ ] **Current Source:** Click to place a current source
- [ ] **Ground:** Click to place a ground symbol
- [ ] **VDD:** Click to place a power supply symbol
- [ ] **Input Pin:** Click to place an input pin (arrow pointing in)
- [ ] **Output Pin:** Click to place an output pin (arrow pointing out)
- [ ] **Inout Pin:** Click to place a bidirectional pin

### Library & File
- [ ] **Browse Library (Ctrl+Insert or Insert key):** A library browser window opens showing available components — you can pick one and place it
- [ ] **From File (Ctrl+Shift+E or Insert → From File):** A file explorer opens — you can pick a `.chn` file to insert as a sub-circuit

---

## 7. Drawing Wires

- [ ] **Start Wire Mode (W):** Press W — cursor changes to wire drawing mode
- [ ] **Place Wire:** In wire mode, click to start a wire, click again to place a segment. Each click adds another segment
- [ ] **Orthogonal Routing Toggle (Shift+L):** While in wire mode, toggles between straight lines and right-angle routing
- [ ] **Wire Snap (Shift+W):** Starts wire mode with snapping enabled
- [ ] **Exit Wire Mode (Escape):** Press Escape to go back to select mode, canceling any in-progress wire
- [ ] **Break Wires (`:breakwires`):** Splits a wire at the selected point
- [ ] **Join Wires (`:joinwires`):** Merges two connected wire segments into one

---

## 8. Drawing Shapes

- [ ] **Line (L):** Press L — draw a line by clicking start and end points
- [ ] **Rectangle (`:rect`):** Draw a rectangle by clicking two corner points
- [ ] **Polygon (P):** Press P — click to add polygon points, press Escape or close the shape to finish
- [ ] **Text (T):** Press T — click to place text on the canvas
- [ ] **Arc:** Draw an arc (via menu or command)
- [ ] **Circle:** Draw a circle (via menu or command)

---

## 9. Editing Components

- [ ] **Move (M):** Press M — selected components follow your mouse. Click to drop them in the new position
- [ ] **Copy (C):** Press C — makes a copy of selected components that follows your mouse. Click to place the copy
- [ ] **Duplicate (D):** Press D — instantly creates a duplicate of selected components, offset slightly
- [ ] **Delete (Del):** Press Delete — removes all selected components and wires
- [ ] **Cut (Ctrl+X):** Cuts selected items to clipboard — they disappear from canvas
- [ ] **Copy to Clipboard (Ctrl+C):** Copies selected items to clipboard — they stay on canvas
- [ ] **Paste (Ctrl+V):** Pastes items from clipboard onto canvas
- [ ] **Rotate Clockwise (R):** Rotates selected items 90° clockwise
- [ ] **Rotate Counter-Clockwise (Shift+R):** Rotates selected items 90° counter-clockwise
- [ ] **Flip Horizontal (X):** Flips selected items left-to-right (mirror)
- [ ] **Flip Vertical (Shift+X):** Flips selected items top-to-bottom (mirror)
- [ ] **Nudge with Arrow Keys:** Press arrow keys (Left/Right/Up/Down) — selected items move one grid step in that direction
- [ ] **Align to Grid:** Snaps selected items so they sit exactly on grid points

---

## 10. Undo / Redo

- [ ] **Undo (Ctrl+Z):** Undoes the last action — the change reverses
- [ ] **Redo (Ctrl+Y):** Redoes the last undone action — the change comes back
- [ ] **Multiple Undos:** Press Ctrl+Z several times — each press undoes one more step
- [ ] **Multiple Redos:** Press Ctrl+Y several times — each press redoes one more step
- [ ] **Undo after Delete:** Delete something, then undo — deleted items reappear

---

## 11. Properties Dialog

- [ ] **Open Properties (Q or double-click):** Select a component, press Q (or double-click it) — a properties window opens
- [ ] **View Properties:** Shows component name, type, and pin count
- [ ] **Edit Properties:** You can change property values (key-value pairs like "value=10k")
- [ ] **Apply Button:** Click Apply — properties are saved and dialog closes
- [ ] **Cancel Button:** Click Cancel — changes are thrown away
- [ ] **Multi-Select Properties:** Select multiple components, right-click → "Edit All Properties" — shows all selected items' properties

---

## 12. Right-Click Context Menus

### On a Component
- [ ] **Properties [Q]:** Opens the properties dialog
- [ ] **Delete [Del]:** Deletes the component
- [ ] **Rotate CW [R]:** Rotates the component clockwise
- [ ] **Flip H [X]:** Flips the component horizontally
- [ ] **Move [M]:** Starts interactive move
- [ ] **Descend [E]:** Opens the component's internal schematic (if it has one)

### On a Wire
- [ ] **Delete [Del]:** Deletes the wire
- [ ] **Select Connected:** Selects all wires connected to this one

### On Multiple Selected Items
- [ ] **Edit All Properties:** Opens batch property editor
- [ ] **Delete [Del]:** Deletes all selected items
- [ ] **Rotate CW [R]:** Rotates all selected items
- [ ] **Flip H [X]:** Flips all selected items
- [ ] **Duplicate:** Makes copies of all selected items

### On Empty Canvas
- [ ] **Paste [Ctrl+V]:** Pastes from clipboard
- [ ] **Insert from Library:** Opens the library browser

---

## 13. View Options

- [ ] **Show/Hide Grid:** Toggle the grid dots/lines on or off
- [ ] **Toggle Crosshair:** Shows or hides a crosshair at the viewport center
- [ ] **Toggle Colorscheme (Shift+O):** Switches between light and dark mode
- [ ] **Show Netlist Overlay:** Displays netlist info overlaid on the schematic
- [ ] **Toggle Text in Symbols:** Shows or hides text labels inside symbols
- [ ] **Toggle Symbol Details:** Shows or hides extra details on symbols
- [ ] **Increase Line Width:** Makes lines thicker
- [ ] **Decrease Line Width:** Makes lines thinner
- [ ] **Snap Double (Shift+G):** Doubles the snap grid size (e.g., 10 → 20)
- [ ] **Snap Halve (Ctrl+G):** Halves the snap grid size (e.g., 10 → 5)
- [ ] **Snap indicator in status bar:** Bottom bar shows current snap value (e.g., "snap:10")

---

## 14. Hierarchy Navigation

- [ ] **Descend into Schematic (E):** Select a sub-circuit component, press E — you go inside it and see its internal schematic
- [ ] **Descend into Symbol (I):** Select a component, press I — you see its symbol definition
- [ ] **Ascend / Go Back (Backspace or Ctrl+E):** Go back up to the parent schematic
- [ ] **Edit in New Tab (Alt+E):** Opens the sub-circuit in a new tab instead of descending in-place
- [ ] **Make Symbol from Schematic (A):** Creates a symbol file from the current schematic
- [ ] **Make Schematic from Symbol:** Creates a schematic from the current symbol view

---

## 15. Netlist Generation

- [ ] **Hierarchical Netlist (N):** Generates a full hierarchical SPICE netlist — check status bar for success/error
- [ ] **Top-only Netlist (Shift+N):** Generates a netlist for only the top level
- [ ] **Flat Netlist (menu):** Generates a flattened netlist
- [ ] **Toggle Flat Netlist Mode (menu):** Switches between hierarchical and flat mode for future netlist generation

---

## 16. Simulation

- [ ] **Run ngspice Simulation (F5):** Starts an ngspice simulation — check for output or errors
- [ ] **Run Xyce Simulation (menu):** Starts a Xyce simulation
- [ ] **Open Waveform Viewer (menu or `:wave`):** Opens a window to view simulation waveforms

---

## 17. Net Highlighting

- [ ] **Highlight Selected Nets (K):** Select a wire or component pin, press K — all wires on the same net light up in a highlight color
- [ ] **Unhighlight Selected Nets (Ctrl+K):** Removes the highlight from selected nets
- [ ] **Unhighlight All (Shift+K):** Removes all net highlights everywhere
- [ ] **Select Attached Nets (Alt+K):** Selects all wires and components on the same net

---

## 18. Export

- [ ] **Export PDF (Ctrl+Shift+P or `:exportpdf`):** Saves the schematic as a PDF file
- [ ] **Export PNG (`:exportpng`):** Saves the schematic as a PNG image
- [ ] **Export SVG (`:exportsvg`):** Saves the schematic as an SVG file

---

## 19. Vim Command Mode

- [ ] **Enter Command Mode (`:`):** Press the colon key — a text input appears at the bottom
- [ ] **Type a Command:** Type `:zoomfit` and press Enter — canvas zooms to fit everything
- [ ] **Cancel (Escape):** Press Escape while in command mode — it exits without running anything
- [ ] **Hint Text:** While in command mode, you see "Enter to run • Esc to cancel"
- [ ] **`:undo`** — same as Ctrl+Z
- [ ] **`:redo`** — same as Ctrl+Y
- [ ] **`:selectall`** — selects everything
- [ ] **`:delete`** — deletes selected items
- [ ] **`:wire`** — enters wire mode
- [ ] **`:netlist`** — generates netlist
- [ ] **`:find`** — opens find dialog
- [ ] **`:keybinds`** or **`:help`** — shows keyboard shortcuts dialog
- [ ] **`:q`** or **`:quit`** — exits the application
- [ ] **`:grid`** — toggles grid on/off
- [ ] **`:snap 5`** — sets snap grid size to 5 (or whatever number you type)
- [ ] **`:schematic`** — switches to schematic view
- [ ] **`:symbol`** — switches to symbol view
- [ ] **`:darkmode`** — toggles dark/light mode
- [ ] **`:fullscreen`** — toggles fullscreen
- [ ] **`:tabnew`** — opens new tab
- [ ] **`:tabclose`** — closes current tab
- [ ] **`:tabnext`** / **`:tabprev`** — switch tabs
- [ ] **`:duprefdes`** — highlights duplicate reference designators
- [ ] **`:fixrefdes`** — auto-fixes duplicate reference designators

---

## 20. File Explorer Dialog

- [ ] **Open (Ctrl+Shift+E or Insert → From File or `:explorer`):** A file browser dialog opens
- [ ] **Sections Panel (left):** Shows categories — Components, Testbenches, Primitives, PDK
- [ ] **File List (center):** Shows files in the selected section
- [ ] **Fuzzy Search:** Type in the search box — file list filters in real time
- [ ] **Symbol Preview (right):** Click a `.chn` file — its symbol preview shows on the right
- [ ] **File Badges:** Files have color-coded badges by type
- [ ] **Select a File:** Click a file and confirm — it gets inserted into the schematic

---

## 21. Library Browser

- [ ] **Open (Ctrl+Insert or Insert key):** A floating library window appears
- [ ] **Device List:** Shows built-in devices (Resistor, Capacitor, NMOS, PMOS, Diode, etc.)
- [ ] **Category Badges:** Each device shows a category label (PAC, SEM, etc.)
- [ ] **Pin Count:** Each device shows how many pins it has
- [ ] **Place Selected Button:** Click a device, then click [Place Selected] — the device appears on the canvas
- [ ] **Close Button:** Click [Close] — the library window disappears

---

## 22. Plugin Marketplace

- [ ] **Open (Plugins menu → Plugin Marketplace):** A modal dialog opens
- [ ] **Search Bar:** There's a search box at the top (may be WIP)
- [ ] **Plugin List (left):** Shows available plugins with name, author, version, and tags
- [ ] **Plugin Detail (right):** Click a plugin — its description and README appear on the right
- [ ] **Install Button:** Each plugin has an [Install] button
- [ ] **Open on GitHub:** Link to open the plugin's source code
- [ ] **Custom URL Field:** Text field to enter a custom plugin URL + [Add] button
- [ ] **Status Indicator:** Shows Loading / Failed / Done for the plugin registry

---

## 23. Plugin Panels

- [ ] **Toggle Panels (Plugins menu):** Each installed plugin has a checkbox — toggle it to show/hide its panel
- [ ] **Left Sidebar Panels:** Plugin panels can appear on the left side
- [ ] **Right Sidebar Panels:** Plugin panels can appear on the right side
- [ ] **Overlay Panels:** Plugin panels can float over the canvas
- [ ] **Bottom Bar Panels:** Plugin panels can appear in a bottom bar
- [ ] **Plugin Widgets:** Plugins show buttons, sliders, checkboxes, labels — clicking/changing them sends events to the plugin

---

## 24. Keybinds Help Dialog

- [ ] **Open (`:keybinds` or `:help`):** A dialog opens showing all keyboard shortcuts
- [ ] **Scrollable List:** You can scroll through all the shortcuts
- [ ] **Key + Action Display:** Each entry shows the key combo and what it does
- [ ] **Close Button:** Click close to dismiss

---

## 25. SPICE Code Block Dialog

- [ ] **Open:** Via menu or command — a dialog opens for editing SPICE directives
- [ ] **Edit Area:** You can type SPICE commands (.param, .model, .include, etc.)
- [ ] **Character Count:** Shows how many characters are in the code block
- [ ] **Apply Button:** Saves the SPICE code to the schematic
- [ ] **Cancel Button:** Discards changes

---

## 26. Refdes (Reference Designator) Tools

- [ ] **Highlight Duplicate Refdes (`:duprefdes`):** Components with duplicate names get highlighted
- [ ] **Fix Duplicate Refdes (`:fixrefdes`):** Automatically renames duplicates so every component has a unique name

---

## 27. Grid & Snapping

- [ ] **Grid Visible:** Grid dots/lines are visible on the canvas by default
- [ ] **Grid Toggle:** You can turn the grid on and off
- [ ] **Snap to Grid:** When placing or moving components, they snap to grid points
- [ ] **Snap Size Display:** Bottom status bar shows current snap size (e.g., "snap:10")
- [ ] **Change Snap Size (`:snap <number>`):** Typing `:snap 5` changes snap grid to 5
- [ ] **Snap Double (Shift+G):** Snap size doubles (10 → 20)
- [ ] **Snap Halve (Ctrl+G):** Snap size halves (10 → 5)

---

## 28. Status Bar / Command Bar

- [ ] **Status Messages:** After actions, the status bar shows a message (e.g., "Saved", "Deleted 3 items")
- [ ] **Error Messages:** When something fails, the status bar shows a red/error message
- [ ] **Snap Display:** Shows current snap value
- [ ] **Tool Display:** Shows which tool is active (e.g., "select", "wire")
- [ ] **View Mode Display:** Shows whether you're in schematic or symbol view

---

## 29. Testbench Overlay

Use `examples/nand2.chn` (DUT) and `examples/test.chn_tb` (testbench that instances `nand2`) to test this feature.

- [ ] **Open DUT schematic:** Open `examples/nand2.chn` — a pill button labeled `test` appears in the top-right corner of the canvas
- [ ] **Multiple testbenches:** If more than one `.chn_tb` references the same DUT, one pill per testbench appears stacked vertically
- [ ] **Hover wire overlay:** Hover over the `test` pill — testbench wires ghost-draw over the schematic, and port pins (ipin/opin/iopin) are hidden so connections are visible
- [ ] **Click to open (replace):** Click the `test` pill — current tab closes and `test.chn_tb` opens in its place
- [ ] **Shift+Click to open (new tab):** Shift+click the `test` pill — `test.chn_tb` opens in a new tab alongside `nand2.chn`
- [ ] **No button on testbench itself:** Open `examples/test.chn_tb` directly — no testbench overlay buttons appear
- [ ] **Auto-indexed from Config.toml:** Buttons appear without manually opening `test.chn_tb` first (Config.toml already has `chn_tb = ["examples/*"]`)

---

## 30. Dual Backend (if testing web)

- [ ] **Build Web:** `zig build -Dbackend=web` completes without errors
- [ ] **Serve Web:** `zig build run_local -Dbackend=web` starts a server at http://localhost:8080
- [ ] **Web App Loads:** Opening http://localhost:8080 in a browser shows the Schemify GUI
- [ ] **Canvas Renders:** You see the grid and can interact with the canvas
- [ ] **Keyboard Shortcuts Work:** Pressing keys like W, R, Z works in the browser
- [ ] **Mouse Interactions Work:** Click, drag, scroll, right-click all work in the browser
