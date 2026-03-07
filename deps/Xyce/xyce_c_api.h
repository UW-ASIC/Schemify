/// xyce_c_api.h — Thin C wrapper around Xyce's C++ GenCouplingSimulator API.
///
/// Allows Zig (or any C-ABI consumer) to drive Xyce as an embedded library
/// without needing C++ interop. The opaque XyceHandle wraps a
/// Xyce::Circuit::GenCouplingSimulator instance.

#ifndef XYCE_C_API_H
#define XYCE_C_API_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Opaque handle ──────────────────────────────────────────────────────────

typedef void *XyceHandle;

// ── Lifecycle ──────────────────────────────────────────────────────────────

XyceHandle xyce_create(void);
void xyce_destroy(XyceHandle handle);

// ── Initialization (two-phase) ─────────────────────────────────────────────

/// argv[0] = program name (ignored), argv[1] = netlist path, …
int xyce_initialize_early(XyceHandle handle, int argc, const char **argv);
int xyce_initialize_late(XyceHandle handle);

// ── Simulation ─────────────────────────────────────────────────────────────

int xyce_run_simulation(XyceHandle handle);
int xyce_simulate_until(XyceHandle handle, double requested_time,
                        double *achieved_time);
void xyce_finalize(XyceHandle handle);

// ── Device queries ─────────────────────────────────────────────────────────

/// Fills names_out with up to max_names C-string pointers.
/// Returns count found or -1 on error.
int xyce_get_device_names(XyceHandle handle, const char *device_type,
                          const char **names_out, int max_names);

// ── Parameters ─────────────────────────────────────────────────────────────

int xyce_get_device_param_double(XyceHandle handle, const char *device_name,
                                 const char *param_name, double *value_out);
int xyce_set_device_param_double(XyceHandle handle, const char *device_name,
                                 const char *param_name, double value);

// ── Solution access ────────────────────────────────────────────────────────

/// Writes up to max_len values into soln_out.  Returns count or -1.
int xyce_get_solution(XyceHandle handle, const char *device_name,
                      double *soln_out, int max_len);
int xyce_get_num_vars(XyceHandle handle, const char *device_name);
int xyce_get_num_ext_vars(XyceHandle handle, const char *device_name);

// ── External device coupling (YGENEXT) ─────────────────────────────────────

int xyce_set_num_internal_vars(XyceHandle handle, const char *device_name,
                               int num_internal);
int xyce_set_jac_stamp(XyceHandle handle, const char *device_name,
                       const int *stamp, int rows, int cols);

// ── Utility ────────────────────────────────────────────────────────────────

const char *xyce_version(void);

#ifdef __cplusplus
}
#endif

#endif // XYCE_C_API_H
