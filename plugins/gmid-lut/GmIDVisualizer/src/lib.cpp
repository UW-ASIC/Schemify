#include "gmid/lib.hpp"
#include "gmid/model_validator.hpp"
#include "gmid/plots.hpp"
#include "gmid/simulators/ngspice.hpp"

#include <cstring>
#include <new>

namespace gmid {

// ---------------------------------------------------------------------------
// Helper: zip two parallel vectors into a LutPoint array
// ---------------------------------------------------------------------------

static std::vector<LutPoint> zip_lut(const std::vector<double>& xs,
                                     const std::vector<double>& ys) {
    std::vector<LutPoint> out;
    out.reserve(xs.size());
    for (std::size_t i = 0; i < xs.size(); ++i)
        out.push_back({xs[i], ys[i]});
    return out;
}

// ---------------------------------------------------------------------------
// characterise()
// ---------------------------------------------------------------------------

CharResult characterise(const SweepConfig&           cfg,
                        const std::filesystem::path& out_dir) {
    CharResult cr;

    NgspiceBackend sim;
    auto sweep = sim.run(cfg);
    if (!sweep) {
        cr.error = sweep.error();
        return cr;
    }

    if (cfg.kind == ModelKind::mosfet) {
        // Generate SVGs
        auto svgs = generate_mosfet_set(*sweep, cfg, out_dir);

        // Extract the same mid-VDS slice used for the SVGs
        const auto sl = extract_mosfet_slice(*sweep, cfg);

        // Build per-plot LUTs matching the axis pairs in generate_mosfet_set
        const std::array<std::vector<LutPoint>, 6> luts = {{
            zip_lut(sl.gmid, sl.jd),    // gm/Id vs current density
            zip_lut(sl.gmid, sl.gm),    // gm/Id vs gm
            zip_lut(sl.gmid, sl.gds),   // gm/Id vs gds
            zip_lut(sl.gmid, sl.av),    // gm/Id vs intrinsic gain
            zip_lut(sl.vgs,  sl.gmid),  // VGS vs gm/Id
            zip_lut(sl.vgs,  sl.id),    // VGS vs Id
        }};

        cr.plots.reserve(mosfet_specs.size());
        for (std::size_t i = 0; i < mosfet_specs.size(); ++i) {
            cr.plots.push_back({
                .svg     = svgs[i],
                .title   = mosfet_specs[i].title,
                .x_label = mosfet_specs[i].x_label,
                .y_label = mosfet_specs[i].y_label,
                .lut     = luts[i],
            });
        }

    } else {
        auto svgs = generate_bjt_set(*sweep, cfg, out_dir);
        const auto sl = extract_bjt_slice(*sweep, cfg);

        const std::array<std::vector<LutPoint>, 6> luts = {{
            zip_lut(sl.gmic, sl.ic),    // gm/Ic vs collector current
            zip_lut(sl.gmic, sl.gm),    // gm/Ic vs gm
            zip_lut(sl.gmic, sl.av),    // gm/Ic vs intrinsic gain
            zip_lut(sl.gmic, sl.beta),  // gm/Ic vs beta
            zip_lut(sl.vbe,  sl.gmic),  // VBE vs gm/Ic
            zip_lut(sl.vbe,  sl.ic),    // VBE vs Ic
        }};

        cr.plots.reserve(bjt_specs.size());
        for (std::size_t i = 0; i < bjt_specs.size(); ++i) {
            cr.plots.push_back({
                .svg     = svgs[i],
                .title   = bjt_specs[i].title,
                .x_label = bjt_specs[i].x_label,
                .y_label = bjt_specs[i].y_label,
                .lut     = luts[i],
            });
        }
    }

    return cr;
}

} // namespace gmid

// ===========================================================================
// C-linkage implementation
// ===========================================================================

GmidCharResult* gmid_characterise(
    const char* model_file,
    const char* device_name,
    const char* kind,
    const char* out_dir,
    const char* work_dir,
    double vgs_start, double vgs_stop, int vgs_steps,
    double vds_start, double vds_stop, int vds_steps,
    double width_um, double length_um, double temp_c)
{
    auto* cr = new (std::nothrow) GmidCharResult{};
    if (!cr) return nullptr;

    gmid::SweepConfig cfg;
    cfg.model_file  = model_file ? model_file : "";
    cfg.kind        = (kind && std::string_view{kind} == "bjt")
                      ? gmid::ModelKind::bjt
                      : gmid::ModelKind::mosfet;
    cfg.vgs_start   = vgs_start; cfg.vgs_stop  = vgs_stop;  cfg.vgs_steps = vgs_steps;
    cfg.vds_start   = vds_start; cfg.vds_stop  = vds_stop;  cfg.vds_steps = vds_steps;
    cfg.width_um    = width_um;  cfg.length_um = length_um; cfg.temp_c    = temp_c;
    cfg.work_dir    = work_dir ? work_dir
                               : (std::filesystem::path{out_dir ? out_dir : "."} / "work");

    // Resolve device name
    if (device_name && device_name[0] != '\0') {
        cfg.device_name = device_name;
    } else {
        auto name = gmid::extract_device_name(cfg.model_file);
        if (!name) {
            std::snprintf(cr->error, sizeof(cr->error), "%s", name.error().c_str());
            return cr;
        }
        cfg.device_name = std::move(*name);
    }

    cfg.subcircuit = gmid::is_subcircuit(cfg.model_file, cfg.device_name);

    auto result = gmid::characterise(cfg, out_dir ? out_dir : ".");
    if (!result.ok()) {
        std::snprintf(cr->error, sizeof(cr->error), "%s", result.error.c_str());
        return cr;
    }

    const int n = static_cast<int>(result.plots.size());
    cr->plots      = new (std::nothrow) GmidPlotResult[n]{};
    cr->plot_count = n;
    if (!cr->plots) {
        std::snprintf(cr->error, sizeof(cr->error), "out of memory");
        return cr;
    }

    for (int i = 0; i < n; ++i) {
        const auto& p = result.plots[static_cast<std::size_t>(i)];
        auto&       g = cr->plots[i];

        std::snprintf(g.svg_path, sizeof(g.svg_path), "%s", p.svg.c_str());
        std::snprintf(g.title,    sizeof(g.title),    "%.*s",
                      static_cast<int>(p.title.size()),   p.title.data());
        std::snprintf(g.x_label,  sizeof(g.x_label),  "%.*s",
                      static_cast<int>(p.x_label.size()), p.x_label.data());
        std::snprintf(g.y_label,  sizeof(g.y_label),  "%.*s",
                      static_cast<int>(p.y_label.size()), p.y_label.data());

        g.lut_len = static_cast<int>(p.lut.size());
        g.lut     = new (std::nothrow) GmidLutPoint[p.lut.size()];
        if (g.lut) {
            for (int j = 0; j < g.lut_len; ++j)
                g.lut[j] = {p.lut[static_cast<std::size_t>(j)].x,
                             p.lut[static_cast<std::size_t>(j)].y};
        }
    }

    return cr;
}

void gmid_free_result(GmidCharResult* r) {
    if (!r) return;
    for (int i = 0; i < r->plot_count; ++i)
        delete[] r->plots[i].lut;
    delete[] r->plots;
    delete r;
}
