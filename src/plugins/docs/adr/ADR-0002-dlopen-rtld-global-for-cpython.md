# ADR-0002: dlopen with RTLD_GLOBAL for CPython interop

## Status: superseded

Superseded by subprocess-based plugin model.

## Original Decision

Bypassed `std.DynLib` to use glibc's `dlopen` directly with `RTLD_LAZY | RTLD_GLOBAL` so that CPython C extension modules (numpy, scipy) could resolve `libpython` symbols.

## Why It No Longer Applies

Plugins are now separate processes, not shared libraries loaded into the host. Each plugin runs in its own process with its own address space, so symbol visibility, dlclose safety, and CPython teardown concerns are eliminated entirely. The plugin process can embed any interpreter it needs without affecting the host.
