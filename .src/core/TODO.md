addDigitalBlock("name", "RTL Code") use HDLParser to infer symbol and YosysJSON to have the synthesis of it (OPTIONAL), if not, we can ONLY use it for simulations but generating netlists of it FOR layout will fail.

=> Have two logic paths, generateLayoutNetlist, generateSimulationNetlist to handle digital logic. - Must modify UI to add path for generateLayoutNetlist to export a top-level schematic.

Move all digital related stuff to src/core/digital/

In examples/, create custom/ directory with a few examples of digital modules, testbenches, and mixed-signal modules to use for testing and demonstration purposes.
