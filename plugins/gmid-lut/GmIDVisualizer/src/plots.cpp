#include "gmid/plots.hpp"
#include "gmid/math.hpp"
#include "gmid/svg.hpp"
#include "gmid/types.hpp"

#include <cmath>
#include <format>
#include <string>

namespace gmid {

// ---------------------------------------------------------------------------
// Axis tick formatting
// ---------------------------------------------------------------------------

static std::string fmt_tick(double v) {
    const double av = std::abs(v);
    if (av == 0.0)                   return "0";
    if (av >= 1.0  && av < 1'000.0) return std::format("{:.1f}", v);
    if (av >= 0.001 && av < 1.0)    return std::format("{:.3f}", v);
    return std::format("{:.1e}", v);
}

// ---------------------------------------------------------------------------
// Generic SVG renderer  —  takes any PlotSeries with dynamic length
// ---------------------------------------------------------------------------

static void render_svg(const PlotSpec& spec,
                       const PlotSeries& data,
                       const std::filesystem::path& out_path) {
    using namespace math;
    constexpr Canvas C{};

    if (data.x.empty()) return;

    const std::size_t N = data.x.size();

    auto [x_lo, x_hi] = minmax({data.x.data(), N});
    auto [y_lo, y_hi] = minmax({data.y.data(), N});

    const double y_pad = (y_hi - y_lo) * 0.05;
    y_lo -= y_pad;
    y_hi += y_pad;

    std::vector<double> px(N), py(N);
    to_plot_coords({data.x.data(), N}, {data.y.data(), N},
                   {px.data(), N},     {py.data(), N},
                   x_lo, x_hi, y_lo, y_hi,
                   C.margin_l, C.margin_t, C.plot_w, C.plot_h);

    SvgWriter svg;
    svg.begin(C.width, C.height, color::bg);

    for (int i = 0; i <= C.grid_lines; ++i) {
        const double frac = static_cast<double>(i) / C.grid_lines;

        const double gy = C.margin_t + frac * C.plot_h;
        svg.line(C.margin_l, gy, C.width - C.margin_r, gy, color::grid, 0.3);

        const double gx = C.margin_l + frac * C.plot_w;
        svg.line(gx, C.margin_t, gx, C.margin_t + C.plot_h, color::grid, 0.3);

        svg.text(gx, C.margin_t + C.plot_h + 25,
                 fmt_tick(x_lo + frac * (x_hi - x_lo)), color::label, 12);
        svg.text(C.margin_l - 12, gy + 4,
                 fmt_tick(y_hi - frac * (y_hi - y_lo)), color::label, 12, "end");
    }

    const double ax0 = C.margin_l, ay0 = C.margin_t;
    const double ax1 = C.width - C.margin_r, ay1 = C.margin_t + C.plot_h;
    svg.line(ax0, ay0, ax1, ay0, color::grid, 1.0);
    svg.line(ax0, ay1, ax1, ay1, color::grid, 1.0);
    svg.line(ax0, ay0, ax0, ay1, color::grid, 1.0);
    svg.line(ax1, ay0, ax1, ay1, color::grid, 1.0);

    svg.text((C.margin_l + C.width - C.margin_r) / 2.0,
             C.margin_t + C.plot_h + 55, spec.x_label, color::label, 15);
    svg.text(18, (C.margin_t + C.margin_t + C.plot_h) / 2.0,
             spec.y_label, color::label, 15, "middle");
    svg.text((C.margin_l + C.width - C.margin_r) / 2.0,
             C.margin_t - 20, spec.title, color::title, 18);

    svg.polyline({px.data(), N}, {py.data(), N}, color::plot_line, 2.2);
    svg.end();
    svg.write_to(out_path);
}

// ---------------------------------------------------------------------------
// MOSFET slice extraction  (declared in plots.hpp)
// ---------------------------------------------------------------------------

MosfetSlice extract_mosfet_slice(const SweepResult& r, const SweepConfig& cfg) {
    const std::size_t n_vgs   = static_cast<std::size_t>(cfg.vgs_steps);
    const std::size_t vds_mid = static_cast<std::size_t>(cfg.vds_steps / 2);
    const std::size_t base    = vds_mid * n_vgs;
    const double vgs_step     = (cfg.vgs_stop - cfg.vgs_start)
                                / std::max(cfg.vgs_steps - 1, 1);
    const double vds_step     = (cfg.vds_stop - cfg.vds_start)
                                / std::max(cfg.vds_steps - 1, 1);

    MosfetSlice sl;
    sl.vgs.reserve(n_vgs); sl.gmid.reserve(n_vgs); sl.id.reserve(n_vgs);
    sl.jd.reserve(n_vgs);  sl.gm.reserve(n_vgs);   sl.gds.reserve(n_vgs);
    sl.av.reserve(n_vgs);

    // Skip first and last VGS points — central difference needs neighbours
    for (std::size_t i = 1; i + 1 < n_vgs; ++i) {
        const std::size_t k = base + i;
        if (k >= r.size()) break;

        const double id = r.id[k];
        if (id <= 1e-12) continue;   // below threshold — skip

        // gm: central difference within this VDS slice (safe, no block cross)
        const double gm = (r.id[base + i + 1] - r.id[base + i - 1])
                          / (2.0 * vgs_step);
        if (gm <= 0.0) continue;

        // gds: central difference across adjacent VDS slices
        double gds = 0.0;
        if (vds_mid > 0 && vds_mid + 1 < static_cast<std::size_t>(cfg.vds_steps)) {
            const std::size_t k_up = (vds_mid + 1) * n_vgs + i;
            const std::size_t k_dn = (vds_mid - 1) * n_vgs + i;
            if (k_up < r.size() && k_dn < r.size())
                gds = (r.id[k_up] - r.id[k_dn]) / (2.0 * vds_step);
        }
        if (gds <= 0.0) continue;

        const double gmid = gm / id;
        sl.vgs.push_back(r.vgs[k]);
        sl.gmid.push_back(gmid);
        sl.id.push_back(id);
        sl.jd.push_back(id / cfg.width_um);
        sl.gm.push_back(gm);
        sl.gds.push_back(gds);
        sl.av.push_back(gm / gds);
    }
    return sl;
}

// ---------------------------------------------------------------------------
// BJT slice extraction  (declared in plots.hpp)
// ---------------------------------------------------------------------------

BjtSlice extract_bjt_slice(const SweepResult& r, const SweepConfig& cfg) {
    const std::size_t n_vgs   = static_cast<std::size_t>(cfg.vgs_steps);
    const std::size_t vce_mid = static_cast<std::size_t>(cfg.vds_steps / 2);
    const std::size_t base    = vce_mid * n_vgs;
    const double vbe_step     = (cfg.vgs_stop - cfg.vgs_start)
                                / std::max(cfg.vgs_steps - 1, 1);
    const double vce_step     = (cfg.vds_stop - cfg.vds_start)
                                / std::max(cfg.vds_steps - 1, 1);

    BjtSlice sl;
    sl.vbe.reserve(n_vgs); sl.ic.reserve(n_vgs);   sl.gm.reserve(n_vgs);
    sl.gds.reserve(n_vgs); sl.gmic.reserve(n_vgs); sl.av.reserve(n_vgs);
    sl.beta.reserve(n_vgs);

    for (std::size_t i = 1; i + 1 < n_vgs; ++i) {
        const std::size_t k = base + i;
        if (k >= r.size()) break;

        const double ic = r.id[k];
        const double ib = r.vth[k];   // ib stored in vth slot
        if (ic <= 1e-12 || ib <= 1e-20) continue;

        // gm: central difference within VCE slice
        const double gm = (r.id[base + i + 1] - r.id[base + i - 1])
                          / (2.0 * vbe_step);
        if (gm <= 0.0) continue;

        // gds (go): central difference across VCE slices
        double gds = 0.0;
        if (vce_mid > 0 && vce_mid + 1 < static_cast<std::size_t>(cfg.vds_steps)) {
            const std::size_t k_up = (vce_mid + 1) * n_vgs + i;
            const std::size_t k_dn = (vce_mid - 1) * n_vgs + i;
            if (k_up < r.size() && k_dn < r.size())
                gds = (r.id[k_up] - r.id[k_dn]) / (2.0 * vce_step);
        }
        if (gds <= 0.0) continue;

        sl.vbe.push_back(r.vgs[k]);
        sl.ic.push_back(ic);
        sl.gm.push_back(gm);
        sl.gds.push_back(gds);
        sl.gmic.push_back(gm / ic);
        sl.av.push_back(gm / gds);
        sl.beta.push_back(ic / ib);
    }
    return sl;
}

// ===========================================================================
// Public API
// ===========================================================================

std::vector<std::filesystem::path>
generate_mosfet_set(const SweepResult& data, const SweepConfig& cfg,
                    const std::filesystem::path& out_dir) {
    std::filesystem::create_directories(out_dir);

    const auto sl = extract_mosfet_slice(data, cfg);

    const std::array<PlotSeries, 6> series {{
        {sl.gmid, sl.jd},    // gm/Id vs current density
        {sl.gmid, sl.gm},    // gm/Id vs gm
        {sl.gmid, sl.gds},   // gm/Id vs gds
        {sl.gmid, sl.av},    // gm/Id vs intrinsic gain
        {sl.vgs,  sl.gmid},  // VGS vs gm/Id
        {sl.vgs,  sl.id},    // VGS vs Id
    }};

    std::vector<std::filesystem::path> paths;
    paths.reserve(mosfet_specs.size());
    for (std::size_t i = 0; i < mosfet_specs.size(); ++i) {
        auto out_path = out_dir / mosfet_specs[i].filename;
        render_svg(mosfet_specs[i], series[i], out_path);
        paths.push_back(std::move(out_path));
    }
    return paths;
}

std::vector<std::filesystem::path>
generate_bjt_set(const SweepResult& data, const SweepConfig& cfg,
                 const std::filesystem::path& out_dir) {
    std::filesystem::create_directories(out_dir);

    const auto sl = extract_bjt_slice(data, cfg);

    const std::array<PlotSeries, 6> series {{
        {sl.gmic, sl.ic},    // gm/Ic vs collector current density
        {sl.gmic, sl.gm},    // gm/Ic vs gm
        {sl.gmic, sl.av},    // gm/Ic vs intrinsic gain
        {sl.gmic, sl.beta},  // gm/Ic vs beta
        {sl.vbe,  sl.gmic},  // VBE vs gm/Ic
        {sl.vbe,  sl.ic},    // VBE vs Ic
    }};

    std::vector<std::filesystem::path> paths;
    paths.reserve(bjt_specs.size());
    for (std::size_t i = 0; i < bjt_specs.size(); ++i) {
        auto out_path = out_dir / bjt_specs[i].filename;
        render_svg(bjt_specs[i], series[i], out_path);
        paths.push_back(std::move(out_path));
    }
    return paths;
}

} // namespace gmid
