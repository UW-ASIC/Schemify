### Implement this

Use GSD (Get Shit Done), Plan out this project, how it connects to the core and state. - The goal is. Get everything xschem project convertible to schemify

Testing:
The testing architecture works like this.
We will build a tree of xschem file dependencies (hierarchy) the bottom of the tree, the leaves, get transformed into schemify, and then their parents and so forth. - Now to clarify "transform", the transform works by using the Schemify struct add and remove features, if we use the struct's IR right away we could pass in xschem kinks that are bad and result in undisplayable Schemify code.

After transforming the tree of this project. aka all the files in it.
Then we will search for: - the .sch and .sym pairs (they have the same names just different extensions) and use the xschem netlist on the .sym, compare that to the netlist produced from the schemify object (the .chn file internally). - the .sch soles and use the xschem netlist on them, compare that to the netlist produced from the schemify object (the .chn_tb file internally). - the .sym soles and use the xschem netlist on them, compare that to the netlist produced from the schemify object (the .chn_prim file internally). - Notice, their netlist NETS may have different names, so we need a function that compares netlists by their connectivity, not by their net names.

For reference, look at the core to understand how our core works, look at how digital components are represented.

You are free to add builtin devices IF necessary.
