#include "gmid/svg.hpp"

#include <cstdio>
#include <format>
#include <iterator>

namespace gmid {

SvgWriter::SvgWriter(std::size_t reserve) {
    buf_.reserve(reserve);
}

void SvgWriter::begin(int width, int height, std::string_view bg) {
    std::format_to(std::back_inserter(buf_),
        R"(<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}">)"
        R"(<rect width="100%" height="100%" fill="{}"/>)"
        "\n",
        width, height, bg);
}

void SvgWriter::end() {
    buf_ += "</svg>\n";
}

void SvgWriter::line(double x1, double y1, double x2, double y2,
                     std::string_view stroke, double w) {
    std::format_to(std::back_inserter(buf_),
        R"(<line x1="{:.1f}" y1="{:.1f}" x2="{:.1f}" y2="{:.1f}" )"
        R"(stroke="{}" stroke-width="{:.1f}"/>)"
        "\n",
        x1, y1, x2, y2, stroke, w);
}

void SvgWriter::text(double x, double y, std::string_view content,
                     std::string_view fill, int font_size,
                     std::string_view anchor,
                     std::string_view font_family) {
    std::format_to(std::back_inserter(buf_),
        R"(<text x="{:.1f}" y="{:.1f}" fill="{}" font-size="{}" )"
        R"(text-anchor="{}" font-family="{}">{}</text>)"
        "\n",
        x, y, fill, font_size, anchor, font_family, content);
}

void SvgWriter::polyline(std::span<const double> px,
                         std::span<const double> py,
                         std::string_view stroke, double w) {
    std::format_to(std::back_inserter(buf_),
        R"(<polyline fill="none" stroke="{}" stroke-width="{:.1f}" points=")",
        stroke, w);

    for (std::size_t i = 0; i < px.size(); ++i) {
        if (i > 0) buf_ += ' ';
        std::format_to(std::back_inserter(buf_), "{:.1f},{:.1f}", px[i], py[i]);
    }

    buf_ += R"("/>)";
    buf_ += '\n';
}

bool SvgWriter::write_to(const std::filesystem::path& path) const {
    // .string(): path::c_str() is wchar_t* on windows.
    std::FILE* f = std::fopen(path.string().c_str(), "wb");
    if (!f) return false;
    std::fwrite(buf_.data(), 1, buf_.size(), f);
    std::fclose(f);
    return true;
}

} // namespace gmid
