#pragma once

#include <cstddef>
#include <filesystem>
#include <span>
#include <string>
#include <string_view>

namespace gmid {

// ---------------------------------------------------------------------------
// SvgWriter  —  buffer-based SVG builder.
//
// Reserves a single contiguous buffer up front; all append operations write
// directly into it via std::format_to (no intermediate allocations).
// ---------------------------------------------------------------------------

class SvgWriter {
public:
    explicit SvgWriter(std::size_t reserve = 32768);

    // Document envelope
    void begin(int width, int height, std::string_view bg);
    void end();

    // Primitives
    void line(double x1, double y1, double x2, double y2,
              std::string_view stroke, double width = 1.0);

    void text(double x, double y, std::string_view content,
              std::string_view fill, int font_size = 14,
              std::string_view anchor = "middle",
              std::string_view font_family = "monospace");

    void polyline(std::span<const double> px, std::span<const double> py,
                  std::string_view stroke, double width = 2.2);

    // Output
    [[nodiscard]] std::string_view view() const noexcept { return buf_; }
    bool write_to(const std::filesystem::path& path) const;

    void clear() noexcept { buf_.clear(); }

private:
    std::string buf_;
};

} // namespace gmid
