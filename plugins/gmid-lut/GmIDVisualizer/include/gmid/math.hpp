#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <span>

namespace gmid::math {

// ---------------------------------------------------------------------------
// constexpr linspace  —  fills a std::array at compile time when possible
// ---------------------------------------------------------------------------

template <std::size_t N>
constexpr std::array<double, N> linspace(double start, double stop) {
    std::array<double, N> out{};
    if constexpr (N == 0) return out;
    if constexpr (N == 1) { out[0] = start; return out; }
    const double step = (stop - start) / static_cast<double>(N - 1);
    for (std::size_t i = 0; i < N; ++i)
        out[i] = start + static_cast<double>(i) * step;
    return out;
}

// ---------------------------------------------------------------------------
// Fast exp approximation  (Schraudolph, IEEE-754 bit trick, ~1 % error)
// Good enough for synthetic visualisation data — not for SPICE.
// ---------------------------------------------------------------------------

inline double fast_exp(double x) noexcept {
    // Clamp to avoid overflow / underflow
    x = std::clamp(x, -708.0, 709.0);
    // Schraudolph's method (double precision variant)
    union { double d; std::int64_t i; } u{};
    u.i = static_cast<std::int64_t>(6497320848556798.0 * x + 4606794787188039910.0);
    return u.d;
}

// ---------------------------------------------------------------------------
// Normalise a value into [0, 1]
// ---------------------------------------------------------------------------

constexpr double normalise(double v, double lo, double hi) noexcept {
    return (hi == lo) ? 0.0 : (v - lo) / (hi - lo);
}

// ---------------------------------------------------------------------------
// Min / max over a span  (auto-vectorisable tight loop)
// ---------------------------------------------------------------------------

struct MinMax { double lo, hi; };

inline MinMax minmax(std::span<const double> v) noexcept {
    double lo = v[0], hi = v[0];
    for (std::size_t i = 1; i < v.size(); ++i) {
        if (v[i] < lo) lo = v[i];
        if (v[i] > hi) hi = v[i];
    }
    return {lo, hi};
}

// ---------------------------------------------------------------------------
// Bulk data → SVG-coordinate transform  (vectorise-friendly, no branching)
//
//   px[i] = margin_l  + norm_x(x[i]) * plot_w
//   py[i] = margin_t  + (1 - norm_y(y[i])) * plot_h      (SVG Y is flipped)
// ---------------------------------------------------------------------------

inline void to_plot_coords(
        std::span<const double> xs, std::span<const double> ys,
        std::span<double>       px, std::span<double>       py,
        double x_lo, double x_hi, double y_lo, double y_hi,
        int margin_l, int margin_t, int plot_w, int plot_h) noexcept
{
    const double inv_x = (x_hi == x_lo) ? 0.0 : 1.0 / (x_hi - x_lo);
    const double inv_y = (y_hi == y_lo) ? 0.0 : 1.0 / (y_hi - y_lo);
    const double pw    = static_cast<double>(plot_w);
    const double ph    = static_cast<double>(plot_h);
    const double ml    = static_cast<double>(margin_l);
    const double mt    = static_cast<double>(margin_t);

    const std::size_t n = xs.size();
    for (std::size_t i = 0; i < n; ++i) {
        const double nx = (xs[i] - x_lo) * inv_x;
        const double ny = (ys[i] - y_lo) * inv_y;
        px[i] = ml + nx * pw;
        py[i] = mt + (1.0 - ny) * ph;
    }
}

} // namespace gmid::math
