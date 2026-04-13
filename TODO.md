Current Issues:

# DOD + Code Quality Refactor Plan

Rules: zero functionality loss, follow CLAUDE.md module structure, prefer Zig utility types
(std.MultiArrayList, arenas, comptime StaticStringMap, ring buffers, flat arrays).
Execute phases in order — each phase unblocks the next.

## Final Phase:

Need solid examples to test the GUI functionality below on:

- Plugins
  - EasyImport needs better symbol sizing/migration because they don't connect.
  - This will generate the test sets that I need ot validate the Netlist generation of digital modules and
  - Netlist generationa and SPice Integration.

- Creating Digital Modules for Mixed-Signal Simulation
- Netlist generation for a valid testbench and runs in a terminal spawned by us.
- SPICE Integration with the primitives all work, spice probes, and graphs, and all the other ocmponents

3. Need to work on GUI and make sure all is modular, all is nice looking and fully functional.
   - Things to test:
     - SPICE Running through the GUI.
     - Everything displays correctly on the GUI.
     - Testbench overlay working on the renderer.
     - All the buttons work.
     - Plugin pnaels work and are modular.
       - All Plugins work as well.
   - Add debug output for plugins if there is osmething wrong.
