Use oh-my-claude and do the following:

## 2. GUI Redesign

### Planning Phase

- Define a complete **UI plan**, including:
  - Layout and structure
  - All components (buttons, panels, etc.)
  - Behavior and interactions for each element

### Implementation Phase

- Rebuild the entire `gui/` module:
  - Follow the same architectural rules from Step 1
  - Create components/ so we can minimize the lines of code.
  - Ensure implementation aligns with the UI plan

-> Merge state.zig into types.zig, dont treat it separately.

3. Remove all Arch.md, move that into the module specific docs/
