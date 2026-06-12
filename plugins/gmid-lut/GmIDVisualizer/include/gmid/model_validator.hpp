#pragma once

#include "types.hpp"

#include <expected>
#include <filesystem>
#include <string>

namespace gmid {

// ---------------------------------------------------------------------------
// Model-file validation
//
// Reads up to 2 MB of a SPICE model file and classifies it as MOSFET, BJT,
// or unknown based on keyword heuristics.  Returns std::unexpected on I/O
// failure.
// ---------------------------------------------------------------------------

std::expected<ModelKind, std::string>
validate_model_file(const std::filesystem::path& path);

// Scan the file for the first ".model <name>" statement and return the name.
std::expected<std::string, std::string>
extract_device_name(const std::filesystem::path& path);

// Returns true if `device_name` is defined via .subckt rather than bare .model.
bool is_subcircuit(const std::filesystem::path& path,
                   const std::string& device_name);

// Returns the number of pins in the .subckt definition for `device_name`,
// or 0 if not found.  Checks the file and its siblings.
int subcircuit_pin_count(const std::filesystem::path& path,
                         const std::string& device_name);

// Recursively resolve all .include directives in a SPICE file.
// Returns the fully flattened content with all includes inlined.
// Handles circular includes and resolves relative paths from each file's dir.
std::expected<std::string, std::string>
resolve_includes(const std::filesystem::path& path);

// Resolve a model file and all its sibling mismatch files into a single
// flattened string.  Mismatch files are resolved first, then the model file.
// Deduplicates across all files (a file included by mismatch won't be
// re-inlined when the model file also includes it).
std::expected<std::string, std::string>
resolve_model_with_deps(const std::filesystem::path& model_file);

} // namespace gmid
