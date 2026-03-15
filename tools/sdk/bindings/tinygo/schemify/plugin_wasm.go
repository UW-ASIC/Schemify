//go:build ignore

// This file is superseded by plugin.go in ABI v6.
//
// plugin.go now handles both native (.so) and WASM targets without build tags,
// cgo, or //go:wasmimport declarations.  Delete this file from your project if
// you have a copy.
//
// Migration from ABI v5:
//   - Remove all //go:wasmimport host … declarations from your plugin
//   - Remove schemify_on_load / schemify_on_tick / schemify_on_unload exports
//   - Remove the draw export (e.g. go_hello_draw)
//   - Implement the schemify.Plugin interface
//   - Export a single schemify_process function that calls schemify.RunPlugin
//
// See plugin.go package-level comment for a full skeleton.
package schemify
