# ADR-0002: dlopen with RTLD_GLOBAL for CPython interop

## Status: accepted

## Context

Several plugins (CCreator, PDKSwitcher, Optimizer) embed CPython via `libpython3.x.so`. CPython's C extension modules (numpy, scipy) are themselves `.so` files that CPython loads via its own `dlopen`. These extensions expect `libpython` symbols to be globally visible.

Zig's `std.DynLib` uses a userspace ELF loader (`ElfDynLib`) when `link_libc` is false. Libraries loaded this way are invisible to glibc's `dlopen`, so CPython extensions cannot resolve their host symbols and crash with undefined symbol errors.

## Decision

Bypass `std.DynLib` entirely. Use glibc's `dlopen` directly with `RTLD_LAZY | RTLD_GLOBAL`. This makes all symbols from the plugin (and its transitive dependencies including libpython) globally available for subsequent dlopen calls.

## Consequences

- **CPython plugins work**: numpy, scipy, and other C extensions load correctly.
- **Symbol namespace pollution**: every plugin's symbols are globally visible. Two plugins exporting the same non-`schemify_` symbol will collide silently. No isolation between plugins.
- **dlclose is unsafe**: CPython does not support being unloaded. `deinit()` skips `dlclose` entirely, leaking all plugin .so mappings for the process lifetime. This prevents true hot reload -- `refresh()` unloads logically but the old code remains mapped.
- **Linux-only**: the `dlopen`/`dlsym`/`dlclose` externs assume glibc. macOS and Windows would need platform-specific loading (already stubbed via `builtin.os.tag` but not implemented).
- **Security implication**: RTLD_GLOBAL means a malicious plugin's symbols are visible to all other plugins. Combined with the unwired safety system (inspectElf exists but is never called before loading), there is no defense-in-depth against supply chain attacks on plugin binaries.
