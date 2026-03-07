/// xyce_c_api.cpp — Implementation of the C wrapper around Xyce's C++ API.
///
/// Build manually:
///   g++ -shared -fPIC -o libxyce_c.so xyce_c_api.cpp \
///     -I<xyce-install>/include -L<xyce-install>/lib -lxyce
///
/// Or let the Zig build system compile it via tools/build_dep.zig.

#include "xyce_c_api.h"
#include "N_CIR_GenCouplingSimulator.h"
#include "Xyce_config.h"

#include <new>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Wrapper — holds the simulator + cached strings for lifetime management
// ---------------------------------------------------------------------------

struct XyceWrapper {
  Xyce::Circuit::GenCouplingSimulator sim;
  std::vector<std::string> cached_names;
  std::vector<const char *> cached_ptrs;
};

static inline XyceWrapper *W(XyceHandle h) {
  return static_cast<XyceWrapper *>(h);
}

// ── Lifecycle ──────────────────────────────────────────────────────────────

extern "C" {

XyceHandle xyce_create(void) {
  try {
    return static_cast<XyceHandle>(new XyceWrapper());
  } catch (...) {
    return nullptr;
  }
}

void xyce_destroy(XyceHandle h) { delete W(h); }

// ── Initialization ─────────────────────────────────────────────────────────

int xyce_initialize_early(XyceHandle h, int argc, const char **argv) {
  if (!h)
    return -1;
  try {
    return W(h)->sim.initializeEarly(argc, const_cast<char **>(argv)) ? 0 : 1;
  } catch (...) {
    return -1;
  }
}

int xyce_initialize_late(XyceHandle h) {
  if (!h)
    return -1;
  try {
    return W(h)->sim.initializeLate() ? 0 : 1;
  } catch (...) {
    return -1;
  }
}

// ── Simulation ─────────────────────────────────────────────────────────────

int xyce_run_simulation(XyceHandle h) {
  if (!h)
    return -1;
  try {
    return W(h)->sim.runSimulation() ? 0 : 1;
  } catch (...) {
    return -1;
  }
}

int xyce_simulate_until(XyceHandle h, double req, double *achieved) {
  if (!h || !achieved)
    return -1;
  try {
    return W(h)->sim.simulateUntil(req, *achieved) ? 0 : 1;
  } catch (...) {
    return -1;
  }
}

void xyce_finalize(XyceHandle h) {
  if (!h)
    return;
  try {
    W(h)->sim.finalize();
  } catch (...) {
  }
}

// ── Device queries ─────────────────────────────────────────────────────────

int xyce_get_device_names(XyceHandle h, const char *type, const char **out,
                          int max) {
  if (!h || !type || !out || max <= 0)
    return -1;
  try {
    auto *w = W(h);
    w->cached_names.clear();
    w->cached_ptrs.clear();
    if (!w->sim.getDeviceNames(std::string(type), w->cached_names))
      return -1;
    int n = 0;
    for (auto &s : w->cached_names) {
      if (n >= max)
        break;
      w->cached_ptrs.push_back(s.c_str());
      out[n++] = w->cached_ptrs.back();
    }
    return n;
  } catch (...) {
    return -1;
  }
}

// ── Parameters ─────────────────────────────────────────────────────────────

int xyce_get_device_param_double(XyceHandle h, const char *dev,
                                 const char *param, double *val) {
  if (!h || !dev || !param || !val)
    return -1;
  try {
    return W(h)->sim.getDeviceParamVal(std::string(dev), std::string(param),
                                       *val)
               ? 0
               : 1;
  } catch (...) {
    return -1;
  }
}

int xyce_set_device_param_double(XyceHandle h, const char *dev,
                                 const char *param, double val) {
  if (!h || !dev || !param)
    return -1;
  try {
    return W(h)->sim.setDeviceParamVal(std::string(dev), std::string(param),
                                       val)
               ? 0
               : 1;
  } catch (...) {
    return -1;
  }
}

// ── Solution access ────────────────────────────────────────────────────────

int xyce_get_solution(XyceHandle h, const char *dev, double *out, int max) {
  if (!h || !dev || !out || max <= 0)
    return -1;
  try {
    std::vector<double> soln;
    if (!W(h)->sim.getSolution(std::string(dev), soln))
      return -1;
    int n = 0;
    for (auto v : soln) {
      if (n >= max)
        break;
      out[n++] = v;
    }
    return n;
  } catch (...) {
    return -1;
  }
}

int xyce_get_num_vars(XyceHandle h, const char *dev) {
  if (!h || !dev)
    return -1;
  try {
    int n = 0;
    return W(h)->sim.getNumVars(std::string(dev), n) ? n : -1;
  } catch (...) {
    return -1;
  }
}

int xyce_get_num_ext_vars(XyceHandle h, const char *dev) {
  if (!h || !dev)
    return -1;
  try {
    int n = 0;
    return W(h)->sim.getNumExtVars(std::string(dev), n) ? n : -1;
  } catch (...) {
    return -1;
  }
}

// ── External device coupling ───────────────────────────────────────────────

int xyce_set_num_internal_vars(XyceHandle h, const char *dev, int num) {
  if (!h || !dev)
    return -1;
  try {
    return W(h)->sim.setNumInternalVars(std::string(dev), num) ? 0 : 1;
  } catch (...) {
    return -1;
  }
}

int xyce_set_jac_stamp(XyceHandle h, const char *dev, const int *stamp,
                       int rows, int cols) {
  if (!h || !dev || !stamp || rows <= 0 || cols <= 0)
    return -1;
  try {
    std::vector<std::vector<int>> js(rows);
    for (int r = 0; r < rows; ++r) {
      js[r].assign(stamp + r * cols, stamp + r * cols + cols);
    }
    return W(h)->sim.setJacStamp(std::string(dev), js) ? 0 : 1;
  } catch (...) {
    return -1;
  }
}

// ── Utility ────────────────────────────────────────────────────────────────

const char *xyce_version(void) {
#ifdef Xyce_VERSION_STRING
  return Xyce_VERSION_STRING;
#else
  return "unknown (built from source)";
#endif
}

} // extern "C"
