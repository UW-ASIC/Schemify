# ADR-001: Custom Tcl Subset Interpreter for xschemrc

## Status
Accepted

## Context
XSchem projects use `xschemrc` files (Tcl scripts) to configure library paths, share directories, and PDK roots. Schemify needs to evaluate these files to discover where symbols live on disk. The options were:

1. **Embed libtcl via C FFI** -- full Tcl semantics, exact parity with XSchem.
2. **Shell out to `tclsh`** -- requires Tcl installed on the user's system.
3. **Regex/pattern match** -- extract `set VAR value` lines without evaluation.
4. **Custom subset interpreter** -- implement enough Tcl to handle real xschemrc files.

## Decision
Option 4: custom subset interpreter (~860 LOC evaluator + ~400 LOC tokenizer/commands/expr).

## Consequences

**Why not libtcl (option 1):** Adds a ~2MB native dependency. Zig's C interop works but libtcl requires initialization, cleanup, and careful thread safety. The build matrix doubles (must link libtcl on every platform). XSchem itself embeds Tcl, but Schemify is not XSchem.

**Why not tclsh (option 2):** Makes the import feature fail silently when Tcl is not installed. NixOS, Alpine, minimal containers often lack it. A tool that fails on first use without a clear error is worse than one that partially works.

**Why not regex (option 3):** Real xschemrc files use `[file dirname [info script]]`, `if/else` blocks, `foreach`, `proc`, environment variable substitution, and `source` to include other files. Regex cannot handle these. Tested against 12 real xschemrc files from open-source PDK projects; regex only extracted correct paths from 3 of them.

**What the subset covers:** 22 commands, variable substitution (scalar + `$env()` + array), `expr` with arithmetic/comparison/string ops, `file` subcommands for path manipulation, `source` for file inclusion, `proc` definitions. This handles all path-resolution patterns found in Sky130, GF180MCU, and IHP SG13G2 xschemrc files.

**What it does not cover:** `global`, `package`, `eval`, `uplevel`, `upvar`. These appear in DRC helper procs and simulation setup -- neither affects path resolution. Unsupported constructs return `error.UnsupportedConstruct`, which the caller catches and ignores (partial evaluation is fine for path discovery).

**Reversal cost:** High. 1,600+ LOC of interpreter code, plus all tests. The Tcl subset has become a de facto dependency of the XSchem backend. Switching to libtcl would require ripping this out and rewriting the xschemrc.zig integration layer.
