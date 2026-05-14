//! PyO3 Python bindings — identical API surface to original PySpice.
//!
//! ```python
//! from pyspice_rs import Circuit
//! from pyspice_rs.unit import *
//! ```

#![allow(non_snake_case)]

use std::collections::HashMap;

use pyo3::prelude::*;
use pyo3::exceptions::{PyKeyError, PyAttributeError};

use crate::circuit::{self as cir, ComponentValue, Param};
use crate::unit as u;

/// Convert MeasureResult vec to a Python-friendly dict
fn measures_to_dict(measures: &[crate::result::MeasureResult]) -> HashMap<String, f64> {
    measures.iter().map(|m| (m.name.clone(), m.value)).collect()
}

// ── Unit bindings ──

#[pyclass(name = "Unit")]
#[derive(Clone)]
struct PyUnit {
    inner: u::Unit,
}

#[pyclass(name = "UnitValue")]
#[derive(Clone)]
struct PyUnitValue {
    inner: u::UnitValue,
}

#[pymethods]
impl PyUnit {
    fn __rmatmul__(&self, value: f64) -> PyUnitValue {
        PyUnitValue {
            inner: u::UnitValue::new(value, self.inner),
        }
    }

    fn __repr__(&self) -> String {
        format!("Unit({:?}, {:?})", self.inner.prefix, self.inner.kind)
    }
}

#[pymethods]
impl PyUnitValue {
    #[getter]
    fn value(&self) -> f64 {
        self.inner.value
    }

    fn str_spice(&self) -> String {
        self.inner.str_spice()
    }

    fn __float__(&self) -> f64 {
        self.inner.value
    }

    fn __repr__(&self) -> String {
        format!("{}", self.inner)
    }

    fn __str__(&self) -> String {
        format!("{}", self.inner)
    }
}

// ── Value argument: accept float or UnitValue from Python ──

#[derive(FromPyObject)]
enum PyValueArg {
    Float(f64),
    Unit(PyUnitValue),
}

impl PyValueArg {
    fn into_component_value(self) -> ComponentValue {
        match self {
            Self::Float(v) => ComponentValue::Numeric(v),
            Self::Unit(uv) => ComponentValue::Unit(uv.inner),
        }
    }
}

// ── Circuit bindings ──

#[pyclass(name = "Circuit")]
struct PyCircuit {
    inner: cir::Circuit,
}

#[pymethods]
impl PyCircuit {
    #[new]
    fn new(title: &str) -> Self {
        Self {
            inner: cir::Circuit::new(title),
        }
    }

    #[getter]
    fn gnd(&self) -> String {
        "0".to_string()
    }

    // ── Component methods ──

    #[pyo3(signature = (name, n1, n2, value, raw_spice=None))]
    fn R(&mut self, name: &str, n1: &str, n2: &str, value: PyValueArg, raw_spice: Option<&str>) {
        if let Some(raw) = raw_spice {
            self.inner.r_raw(name, n1, n2, raw);
        } else {
            self.inner.r(name, n1, n2, value.into_component_value());
        }
    }

    fn C(&mut self, name: &str, n1: &str, n2: &str, value: PyValueArg) {
        self.inner.c(name, n1, n2, value.into_component_value());
    }

    fn L(&mut self, name: &str, n1: &str, n2: &str, value: PyValueArg) {
        self.inner.l(name, n1, n2, value.into_component_value());
    }

    fn K(&mut self, name: &str, inductor1: &str, inductor2: &str, coupling: f64) {
        self.inner.k(name, inductor1, inductor2, coupling);
    }

    fn V(&mut self, name: &str, np: &str, nm: &str, value: PyValueArg) {
        self.inner.v(name, np, nm, value.into_component_value());
    }

    fn I(&mut self, name: &str, np: &str, nm: &str, value: PyValueArg) {
        self.inner.i(name, np, nm, value.into_component_value());
    }

    fn BV(&mut self, name: &str, np: &str, nm: &str, expression: &str) {
        self.inner.bv(name, np, nm, expression);
    }

    fn BI(&mut self, name: &str, np: &str, nm: &str, expression: &str) {
        self.inner.bi(name, np, nm, expression);
    }

    #[pyo3(signature = (name, np, nm, ncp, ncm, voltage_gain))]
    fn E(&mut self, name: &str, np: &str, nm: &str, ncp: &str, ncm: &str, voltage_gain: f64) {
        self.inner.e(name, np, nm, ncp, ncm, voltage_gain);
    }

    #[pyo3(signature = (name, np, nm, ncp, ncm, transconductance))]
    fn G(&mut self, name: &str, np: &str, nm: &str, ncp: &str, ncm: &str, transconductance: f64) {
        self.inner.g(name, np, nm, ncp, ncm, transconductance);
    }

    #[pyo3(signature = (name, np, nm, vsense, current_gain))]
    fn F(&mut self, name: &str, np: &str, nm: &str, vsense: &str, current_gain: f64) {
        self.inner.f(name, np, nm, vsense, current_gain);
    }

    #[pyo3(signature = (name, np, nm, vsense, transresistance))]
    fn H(&mut self, name: &str, np: &str, nm: &str, vsense: &str, transresistance: f64) {
        self.inner.h(name, np, nm, vsense, transresistance);
    }

    #[pyo3(signature = (name, np, nm, model))]
    fn D(&mut self, name: &str, np: &str, nm: &str, model: &str) {
        self.inner.d(name, np, nm, model);
    }

    #[pyo3(signature = (name, nc, nb, ne, model))]
    fn Q(&mut self, name: &str, nc: &str, nb: &str, ne: &str, model: &str) {
        self.inner.q(name, nc, nb, ne, model);
    }

    #[pyo3(signature = (name, nc, nb, ne, model))]
    fn BJT(&mut self, name: &str, nc: &str, nb: &str, ne: &str, model: &str) {
        self.inner.q(name, nc, nb, ne, model);
    }

    #[pyo3(signature = (name, nd, ng, ns, nb, model))]
    fn M(&mut self, name: &str, nd: &str, ng: &str, ns: &str, nb: &str, model: &str) {
        self.inner.m(name, nd, ng, ns, nb, model);
    }

    #[pyo3(signature = (name, nd, ng, ns, nb, model))]
    fn MOSFET(&mut self, name: &str, nd: &str, ng: &str, ns: &str, nb: &str, model: &str) {
        self.inner.m(name, nd, ng, ns, nb, model);
    }

    #[pyo3(signature = (name, nd, ng, ns, model))]
    fn J(&mut self, name: &str, nd: &str, ng: &str, ns: &str, model: &str) {
        self.inner.j(name, nd, ng, ns, model);
    }

    #[pyo3(signature = (name, nd, ng, ns, model))]
    fn Z(&mut self, name: &str, nd: &str, ng: &str, ns: &str, model: &str) {
        self.inner.z(name, nd, ng, ns, model);
    }

    #[pyo3(signature = (name, np, nm, ncp, ncm, model))]
    fn S(&mut self, name: &str, np: &str, nm: &str, ncp: &str, ncm: &str, model: &str) {
        self.inner.s(name, np, nm, ncp, ncm, model);
    }

    #[pyo3(signature = (name, np, nm, vcontrol, model))]
    fn W(&mut self, name: &str, np: &str, nm: &str, vcontrol: &str, model: &str) {
        self.inner.w(name, np, nm, vcontrol, model);
    }

    #[pyo3(signature = (name, inp, inm, outp, outm, Z0, TD))]
    fn T(&mut self, name: &str, inp: &str, inm: &str, outp: &str, outm: &str, Z0: f64, TD: f64) {
        self.inner.t(name, inp, inm, outp, outm, Z0, TD);
    }

    #[pyo3(signature = (name, subcircuit_name, *nodes))]
    fn X(&mut self, name: &str, subcircuit_name: &str, nodes: Vec<String>) {
        let node_refs: Vec<&str> = nodes.iter().map(|s| s.as_str()).collect();
        self.inner.x(name, subcircuit_name, node_refs);
    }

    // ── High-level waveform sources ──

    #[pyo3(signature = (name, np, nm, dc_offset=0.0, offset=0.0, amplitude=1.0, frequency=1000.0))]
    fn SinusoidalVoltageSource(
        &mut self, name: &str, np: &str, nm: &str,
        dc_offset: f64, offset: f64, amplitude: f64, frequency: f64,
    ) {
        self.inner.sinusoidal_voltage_source(name, np, nm, dc_offset, offset, amplitude, frequency);
    }

    #[pyo3(signature = (name, np, nm, initial_value=0.0, pulsed_value=1.0, pulse_width=50e-9, period=100e-9, rise_time=1e-9, fall_time=1e-9))]
    fn PulseVoltageSource(
        &mut self, name: &str, np: &str, nm: &str,
        initial_value: f64, pulsed_value: f64, pulse_width: f64,
        period: f64, rise_time: f64, fall_time: f64,
    ) {
        self.inner.pulse_voltage_source(
            name, np, nm, initial_value, pulsed_value, pulse_width,
            period, rise_time, fall_time,
        );
    }

    #[pyo3(signature = (name, np, nm, values))]
    fn PieceWiseLinearVoltageSource(
        &mut self, name: &str, np: &str, nm: &str, values: Vec<(f64, f64)>,
    ) {
        self.inner.pwl_voltage_source(name, np, nm, values);
    }

    #[pyo3(signature = (name, np, nm, dc_offset=0.0, offset=0.0, amplitude=1.0, frequency=1000.0))]
    fn SinusoidalCurrentSource(
        &mut self, name: &str, np: &str, nm: &str,
        dc_offset: f64, offset: f64, amplitude: f64, frequency: f64,
    ) {
        self.inner.sinusoidal_current_source(name, np, nm, dc_offset, offset, amplitude, frequency);
    }

    #[pyo3(signature = (name, np, nm, initial_value=0.0, pulsed_value=1.0, pulse_width=50e-9, period=100e-9, rise_time=1e-9, fall_time=1e-9))]
    fn PulseCurrentSource(
        &mut self, name: &str, np: &str, nm: &str,
        initial_value: f64, pulsed_value: f64, pulse_width: f64,
        period: f64, rise_time: f64, fall_time: f64,
    ) {
        self.inner.pulse_current_source(
            name, np, nm, initial_value, pulsed_value, pulse_width,
            period, rise_time, fall_time,
        );
    }

    // ── Circuit-level directives ──

    #[pyo3(signature = (name, kind, **kwargs))]
    fn model(&mut self, name: &str, kind: &str, kwargs: Option<Bound<'_, pyo3::types::PyDict>>) -> PyResult<()> {
        let mut params = Vec::new();
        if let Some(dict) = kwargs {
            for (k, v) in dict.iter() {
                let key: String = k.extract::<String>()?;
                let val: String = v.str()?.to_string();
                params.push(Param::new(key, val));
            }
        }
        self.inner.model(name, kind, params);
        Ok(())
    }

    fn include(&mut self, path: &str) {
        self.inner.include(path);
    }

    fn lib(&mut self, path: &str, section: &str) {
        self.inner.lib(path, section);
    }

    fn parameter(&mut self, name: &str, value: &str) {
        self.inner.parameter(name, value);
    }

    // ── Accessors ──

    fn __getitem__(&self, name: &str) -> PyResult<String> {
        self.inner
            .element(name)
            .map(|e| e.to_string())
            .ok_or_else(|| PyKeyError::new_err(format!("Element '{}' not found", name)))
    }

    fn element(&self, name: &str) -> PyResult<String> {
        self.__getitem__(name)
    }

    fn node(&self, name: &str) -> String {
        name.to_string()
    }

    fn __str__(&self) -> String {
        self.inner.to_string()
    }

    fn __repr__(&self) -> String {
        format!("Circuit('{}')", self.inner.title)
    }

    // ── Simulator ──

    #[pyo3(signature = (simulator=None))]
    fn simulator(&self, simulator: Option<&str>) -> PySimulator {
        let sim = self.inner.simulator();
        PySimulator {
            inner: if let Some(name) = simulator {
                sim.with_backend(name)
            } else {
                sim
            },
        }
    }
}

// ── Simulator bindings ──

#[pyclass(name = "CircuitSimulator")]
struct PySimulator {
    inner: crate::simulation::CircuitSimulator,
}

#[pymethods]
impl PySimulator {
    // ── Config ──

    #[pyo3(signature = (**kwargs))]
    fn options(&mut self, kwargs: Option<Bound<'_, pyo3::types::PyDict>>) -> PyResult<()> {
        if let Some(dict) = kwargs {
            for (k, v) in dict.iter() {
                let key: String = k.extract::<String>()?;
                let val: String = v.str()?.to_string();
                self.inner.options(key, val);
            }
        }
        Ok(())
    }

    #[pyo3(signature = (**kwargs))]
    fn initial_condition(&mut self, kwargs: Option<Bound<'_, pyo3::types::PyDict>>) -> PyResult<()> {
        if let Some(dict) = kwargs {
            for (k, v) in dict.iter() {
                let node: String = k.extract::<String>()?;
                let val: f64 = v.extract::<f64>()?;
                self.inner.initial_condition(node, val);
            }
        }
        Ok(())
    }

    #[pyo3(signature = (**kwargs))]
    fn node_set(&mut self, kwargs: Option<Bound<'_, pyo3::types::PyDict>>) -> PyResult<()> {
        if let Some(dict) = kwargs {
            for (k, v) in dict.iter() {
                let node: String = k.extract::<String>()?;
                let val: f64 = v.extract::<f64>()?;
                self.inner.node_set(node, val);
            }
        }
        Ok(())
    }

    #[pyo3(signature = (*args))]
    fn save(&mut self, args: Vec<String>) {
        for a in args {
            self.inner.save(a);
        }
    }

    #[pyo3(signature = (*args))]
    fn measure(&mut self, args: Vec<String>) {
        self.inner.measure(args);
    }

    #[setter]
    fn set_save_currents(&mut self, v: bool) {
        self.inner.set_save_currents(v);
    }

    #[getter]
    fn get_save_currents(&self) -> bool {
        false // TODO: expose from inner
    }

    #[setter]
    fn set_temperature(&mut self, temp: f64) {
        self.inner.set_temperature(temp);
    }

    #[setter]
    fn set_nominal_temperature(&mut self, temp: f64) {
        self.inner.set_nominal_temperature(temp);
    }

    // ── Step parameter sweeps ──

    #[pyo3(signature = (param, start, stop, step))]
    fn step(&mut self, param: &str, start: f64, stop: f64, step: f64) {
        self.inner.step(param, start, stop, step);
    }

    #[pyo3(signature = (param, start, stop, step, sweep_type))]
    fn step_sweep(&mut self, param: &str, start: f64, stop: f64, step: f64, sweep_type: &str) {
        self.inner.step_sweep(param, start, stop, step, sweep_type);
    }

    // ── Analysis methods ──

    fn operating_point(&self) -> PyResult<PyOperatingPoint> {
        self.inner
            .operating_point()
            .map(|op| PyOperatingPoint { inner: op })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (**kwargs))]
    fn dc(&self, kwargs: Option<Bound<'_, pyo3::types::PyDict>>) -> PyResult<PyDcAnalysis> {
        let dict = kwargs.ok_or_else(|| {
            pyo3::exceptions::PyValueError::new_err("dc() requires sweep parameters")
        })?;
        let sweeps = extract_dc_sweeps(&dict)?;
        let sweep_refs: Vec<(&str, f64, f64, f64)> = sweeps
            .iter()
            .map(|(v, a, b, c)| (v.as_str(), *a, *b, *c))
            .collect();
        self.inner
            .dc_multi(&sweep_refs)
            .map(|dc| PyDcAnalysis { inner: dc })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (variation="dec", number_of_points=10, start_frequency=1.0, stop_frequency=1e9))]
    fn ac(
        &self, variation: &str, number_of_points: u32,
        start_frequency: f64, stop_frequency: f64,
    ) -> PyResult<PyAcAnalysis> {
        self.inner
            .ac(variation, number_of_points, start_frequency, stop_frequency)
            .map(|ac| PyAcAnalysis { inner: ac })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (step_time, end_time, start_time=None, max_time=None, use_initial_condition=false))]
    fn transient(
        &self, step_time: f64, end_time: f64,
        start_time: Option<f64>, max_time: Option<f64>,
        use_initial_condition: bool,
    ) -> PyResult<PyTransientAnalysis> {
        self.inner
            .transient(step_time, end_time, start_time, max_time, use_initial_condition)
            .map(|t| PyTransientAnalysis { inner: t })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (output_node, ref_node, src, variation="dec", points=10, start_frequency=1e3, stop_frequency=1e8, points_per_summary=None))]
    fn noise(
        &self, output_node: &str, ref_node: &str, src: &str,
        variation: &str, points: u32,
        start_frequency: f64, stop_frequency: f64,
        points_per_summary: Option<u32>,
    ) -> PyResult<PyNoiseAnalysis> {
        self.inner
            .noise(output_node, ref_node, src, variation, points, start_frequency, stop_frequency, points_per_summary)
            .map(|n| PyNoiseAnalysis { inner: n })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (outvar, insrc))]
    fn transfer_function(&self, outvar: &str, insrc: &str) -> PyResult<PyTransferFunctionAnalysis> {
        self.inner
            .transfer_function(outvar, insrc)
            .map(|t| PyTransferFunctionAnalysis { inner: t })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (outvar, insrc))]
    fn tf(&self, outvar: &str, insrc: &str) -> PyResult<PyTransferFunctionAnalysis> {
        self.transfer_function(outvar, insrc)
    }

    #[pyo3(signature = (output_variable))]
    fn dc_sensitivity(&self, output_variable: &str) -> PyResult<PySensitivityAnalysis> {
        self.inner
            .dc_sensitivity(output_variable)
            .map(|s| PySensitivityAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (output_variable, variation="dec", number_of_points=10, start_frequency=100.0, stop_frequency=1e5))]
    fn ac_sensitivity(
        &self, output_variable: &str, variation: &str,
        number_of_points: u32, start_frequency: f64, stop_frequency: f64,
    ) -> PyResult<PySensitivityAnalysis> {
        self.inner
            .ac_sensitivity(output_variable, variation, number_of_points, start_frequency, stop_frequency)
            .map(|s| PySensitivityAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (node1, node2, node3, node4, tf_type, pz_type))]
    fn polezero(
        &self, node1: &str, node2: &str, node3: &str, node4: &str,
        tf_type: &str, pz_type: &str,
    ) -> PyResult<PyPoleZeroAnalysis> {
        self.inner
            .polezero(node1, node2, node3, node4, tf_type, pz_type)
            .map(|p| PyPoleZeroAnalysis { inner: p })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (variation="dec", points=10, start_frequency=100.0, stop_frequency=1e8, f2overf1=None))]
    fn distortion(
        &self, variation: &str, points: u32,
        start_frequency: f64, stop_frequency: f64,
        f2overf1: Option<f64>,
    ) -> PyResult<PyDistortionAnalysis> {
        self.inner
            .distortion(variation, points, start_frequency, stop_frequency, f2overf1)
            .map(|d| PyDistortionAnalysis { inner: d })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    // ── New analysis methods ──

    #[pyo3(signature = (fundamental_frequency, stabilization_time, observe_node, points_per_period=128, harmonics=10))]
    fn pss(
        &self, fundamental_frequency: f64, stabilization_time: f64,
        observe_node: &str, points_per_period: u32, harmonics: u32,
    ) -> PyResult<PyPssAnalysis> {
        self.inner
            .pss(fundamental_frequency, stabilization_time, observe_node, points_per_period, harmonics)
            .map(|p| PyPssAnalysis { inner: p })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (variation="dec", number_of_points=10, start_frequency=1e6, stop_frequency=1e10))]
    fn s_param(
        &self, variation: &str, number_of_points: u32,
        start_frequency: f64, stop_frequency: f64,
    ) -> PyResult<PySParamAnalysis> {
        self.inner
            .s_param(variation, number_of_points, start_frequency, stop_frequency)
            .map(|s| PySParamAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (output_current, input_source, z_in=50.0, z_out=50.0, variation="dec", points=100, start_freq=1e3, stop_freq=1e9))]
    fn network_params(
        &self, output_current: &str, input_source: &str,
        z_in: f64, z_out: f64,
        variation: &str, points: u32,
        start_freq: f64, stop_freq: f64,
    ) -> PyResult<PySParamAnalysis> {
        self.inner
            .network_params(output_current, input_source, z_in, z_out, variation, points, start_freq, stop_freq)
            .map(|s| PySParamAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (fundamental_frequencies, num_harmonics=None))]
    fn harmonic_balance(
        &self, fundamental_frequencies: Vec<f64>,
        num_harmonics: Option<Vec<u32>>,
    ) -> PyResult<PyHarmonicBalanceAnalysis> {
        let nharms = num_harmonics.unwrap_or_else(|| vec![7; fundamental_frequencies.len()]);
        self.inner
            .harmonic_balance(&fundamental_frequencies, &nharms)
            .map(|h| PyHarmonicBalanceAnalysis { inner: h })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (probe, variation="dec", number_of_points=10, start_frequency=1.0, stop_frequency=1e10))]
    fn stability(
        &self, probe: &str, variation: &str, number_of_points: u32,
        start_frequency: f64, stop_frequency: f64,
    ) -> PyResult<PyStabilityAnalysis> {
        self.inner
            .stability(probe, variation, number_of_points, start_frequency, stop_frequency)
            .map(|s| PyStabilityAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    #[pyo3(signature = (step_time, end_time))]
    fn transient_noise(
        &self, step_time: f64, end_time: f64,
    ) -> PyResult<PyTransientNoiseAnalysis> {
        self.inner
            .transient_noise(step_time, end_time)
            .map(|t| PyTransientNoiseAnalysis { inner: t })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    // ── Xyce-specific analysis methods ──

    /// Xyce .SAMPLING Monte Carlo uncertainty quantification.
    ///
    /// `param_distributions` is a list of `(param_name, distribution_spec)` tuples.
    /// Distribution specs: `"normal(mean,stddev)"`, `"uniform(low,high)"`.
    #[pyo3(signature = (num_samples, param_distributions))]
    fn xyce_sampling(
        &self, num_samples: u32,
        param_distributions: Vec<(String, String)>,
    ) -> PyResult<PySamplingAnalysis> {
        let refs: Vec<(&str, &str)> = param_distributions
            .iter()
            .map(|(p, d)| (p.as_str(), d.as_str()))
            .collect();
        self.inner
            .xyce_sampling(num_samples, &refs)
            .map(|s| PySamplingAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// Xyce .EMBEDDEDSAMPLING — embedded Monte Carlo.
    #[pyo3(signature = (num_samples, param_distributions))]
    fn xyce_embedded_sampling(
        &self, num_samples: u32,
        param_distributions: Vec<(String, String)>,
    ) -> PyResult<PySamplingAnalysis> {
        let refs: Vec<(&str, &str)> = param_distributions
            .iter()
            .map(|(p, d)| (p.as_str(), d.as_str()))
            .collect();
        self.inner
            .xyce_embedded_sampling(num_samples, &refs)
            .map(|s| PySamplingAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// Xyce .PCE Polynomial Chaos Expansion.
    #[pyo3(signature = (num_samples, param_distributions, expansion_order=3))]
    fn xyce_pce(
        &self, num_samples: u32,
        param_distributions: Vec<(String, String)>,
        expansion_order: u32,
    ) -> PyResult<PySamplingAnalysis> {
        let refs: Vec<(&str, &str)> = param_distributions
            .iter()
            .map(|(p, d)| (p.as_str(), d.as_str()))
            .collect();
        self.inner
            .xyce_pce(num_samples, &refs, expansion_order)
            .map(|s| PySamplingAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// Xyce .FFT with spectral metrics (ENOB, SFDR, SNR, THD).
    #[pyo3(signature = (signal, np=1024, start=0.0, stop=1e-3, window="HANN", format="UNORM"))]
    fn xyce_fft(
        &self, signal: &str,
        np: u32, start: f64, stop: f64,
        window: &str, format: &str,
    ) -> PyResult<PyXyceFftAnalysis> {
        let options = crate::result::XyceFftOptions {
            np,
            start,
            stop,
            window: window.to_string(),
            format: format.to_string(),
        };
        self.inner
            .xyce_fft(signal, &options)
            .map(|f| PyXyceFftAnalysis { inner: f })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    // ── Spectre-specific analysis methods ──

    /// Spectre parametric sweep wrapping an inner analysis.
    #[pyo3(signature = (param, start, stop, step, inner_analysis, inner_type="ac"))]
    fn spectre_sweep(
        &self, param: &str, start: f64, stop: f64, step: f64,
        inner_analysis: &str, inner_type: &str,
    ) -> PyResult<PyRawData> {
        self.inner
            .spectre_sweep(param, start, stop, step, inner_analysis, inner_type)
            .map(|r| PyRawData { inner: r })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// Spectre Monte Carlo wrapping an inner analysis.
    #[pyo3(signature = (num_iterations, inner_analysis, inner_type="ac", seed=None))]
    fn spectre_montecarlo(
        &self, num_iterations: u32, inner_analysis: &str,
        inner_type: &str, seed: Option<u64>,
    ) -> PyResult<PyRawData> {
        self.inner
            .spectre_montecarlo(num_iterations, inner_analysis, inner_type, seed)
            .map(|r| PyRawData { inner: r })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// SpectreRF Periodic AC (PAC) analysis with automatic PSS prerequisite.
    #[pyo3(signature = (pss_fundamental, pss_stabilization, pss_harmonics=10, variation="dec", points=100, start_freq=1.0, stop_freq=1e9, sweep_type="relative"))]
    fn spectre_pac(
        &self, pss_fundamental: f64, pss_stabilization: f64,
        pss_harmonics: u32, variation: &str, points: u32,
        start_freq: f64, stop_freq: f64, sweep_type: &str,
    ) -> PyResult<PyAcAnalysis> {
        self.inner
            .spectre_pac(
                pss_fundamental, pss_stabilization, pss_harmonics,
                variation, points, start_freq, stop_freq, sweep_type,
            )
            .map(|a| PyAcAnalysis { inner: a })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// SpectreRF Periodic Noise (PNoise) analysis with automatic PSS prerequisite.
    #[pyo3(signature = (pss_fundamental, pss_stabilization, output_node, ref_node, pss_harmonics=10, variation="dec", points=100, start_freq=1.0, stop_freq=1e9))]
    fn spectre_pnoise(
        &self, pss_fundamental: f64, pss_stabilization: f64,
        output_node: &str, ref_node: &str,
        pss_harmonics: u32, variation: &str, points: u32,
        start_freq: f64, stop_freq: f64,
    ) -> PyResult<PyNoiseAnalysis> {
        self.inner
            .spectre_pnoise(
                pss_fundamental, pss_stabilization, pss_harmonics,
                output_node, ref_node, variation, points, start_freq, stop_freq,
            )
            .map(|n| PyNoiseAnalysis { inner: n })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// SpectreRF Periodic Transfer Function (PXF) analysis with automatic PSS prerequisite.
    #[pyo3(signature = (pss_fundamental, pss_stabilization, output_node, source, pss_harmonics=10, variation="dec", points=100, start_freq=1.0, stop_freq=1e9))]
    fn spectre_pxf(
        &self, pss_fundamental: f64, pss_stabilization: f64,
        output_node: &str, source: &str,
        pss_harmonics: u32, variation: &str, points: u32,
        start_freq: f64, stop_freq: f64,
    ) -> PyResult<PyAcAnalysis> {
        self.inner
            .spectre_pxf(
                pss_fundamental, pss_stabilization, pss_harmonics,
                output_node, source, variation, points, start_freq, stop_freq,
            )
            .map(|a| PyAcAnalysis { inner: a })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// SpectreRF Periodic Stability (PSTB) analysis with automatic PSS prerequisite.
    #[pyo3(signature = (pss_fundamental, pss_stabilization, probe, pss_harmonics=10, variation="dec", points=100, start_freq=1.0, stop_freq=1e9))]
    fn spectre_pstb(
        &self, pss_fundamental: f64, pss_stabilization: f64,
        probe: &str, pss_harmonics: u32, variation: &str, points: u32,
        start_freq: f64, stop_freq: f64,
    ) -> PyResult<PyStabilityAnalysis> {
        self.inner
            .spectre_pstb(
                pss_fundamental, pss_stabilization, pss_harmonics,
                probe, variation, points, start_freq, stop_freq,
            )
            .map(|s| PyStabilityAnalysis { inner: s })
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))
    }

    /// List all available simulator backends on this system
    #[staticmethod]
    fn available_backends() -> Vec<String> {
        crate::simulation::CircuitSimulator::available_backends()
    }

    fn __repr__(&self) -> &str {
        "CircuitSimulator"
    }
}

/// Extract DC sweep params: kwargs like Vinput=slice(-2, 5, 0.01)
fn extract_dc_sweeps(dict: &Bound<'_, pyo3::types::PyDict>) -> PyResult<Vec<(String, f64, f64, f64)>> {
    let mut sweeps = Vec::new();
    for (k, v) in dict.iter() {
        let var: String = k.extract::<String>()?;
        let start: f64 = v.getattr("start")?.extract::<f64>()?;
        let stop: f64 = v.getattr("stop")?.extract::<f64>()?;
        let step: f64 = v.getattr("step")?.extract::<f64>()?;
        sweeps.push((var, start, stop, step));
    }
    if sweeps.is_empty() {
        return Err(pyo3::exceptions::PyValueError::new_err(
            "dc() requires at least one sweep parameter",
        ));
    }
    Ok(sweeps)
}

// ── Result bindings ──

/// Raw simulation data wrapper -- returned by spectre_sweep and spectre_montecarlo.
#[pyclass(name = "RawData")]
struct PyRawData {
    inner: crate::result::RawData,
}

#[pymethods]
impl PyRawData {
    #[getter]
    fn title(&self) -> String { self.inner.title.clone() }
    #[getter]
    fn plot_name(&self) -> String { self.inner.plot_name.clone() }
    #[getter]
    fn is_complex(&self) -> bool { self.inner.is_complex }
    #[getter]
    fn variable_names(&self) -> Vec<String> {
        self.inner.variables.iter().map(|v| v.name.clone()).collect()
    }
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        let lower = name.to_lowercase();
        for (i, var) in self.inner.variables.iter().enumerate() {
            if var.name.to_lowercase() == lower {
                if i < self.inner.real_data.len() {
                    return Ok(self.inner.real_data[i].clone());
                }
            }
        }
        Err(PyKeyError::new_err(format!("Variable '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.__getitem__(name)
    }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.measures) }
}

#[pyclass(name = "OperatingPoint")]
struct PyOperatingPoint {
    inner: crate::result::OperatingPoint,
}

#[pymethods]
impl PyOperatingPoint {
    fn __getitem__(&self, name: &str) -> PyResult<f64> {
        self.inner
            .get(name)
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }

    fn __getattr__(&self, name: &str) -> PyResult<f64> {
        self.inner
            .get(name)
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }

    /// Parsed .meas results as {name: value} dict
    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "DcAnalysis")]
struct PyDcAnalysis {
    inner: crate::result::DcAnalysis,
}

#[pymethods]
impl PyDcAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }

    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }

    #[getter]
    fn sweep(&self) -> Vec<f64> {
        self.inner.sweep.clone()
    }

    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "AcAnalysis")]
struct PyAcAnalysis {
    inner: crate::result::AcAnalysis,
}

#[pymethods]
impl PyAcAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }

    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }

    #[getter]
    fn frequency(&self) -> Vec<f64> {
        self.inner.frequency.clone()
    }

    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "TransientAnalysis")]
struct PyTransientAnalysis {
    inner: crate::result::TransientAnalysis,
}

#[pymethods]
impl PyTransientAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }

    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }

    #[getter]
    fn time(&self) -> Vec<f64> {
        self.inner.time.clone()
    }

    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "NoiseAnalysis")]
struct PyNoiseAnalysis {
    inner: crate::result::NoiseAnalysis,
}

#[pymethods]
impl PyNoiseAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "TransferFunctionAnalysis")]
struct PyTransferFunctionAnalysis {
    inner: crate::result::TransferFunctionAnalysis,
}

#[pymethods]
impl PyTransferFunctionAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "SensitivityAnalysis")]
struct PySensitivityAnalysis {
    inner: crate::result::SensitivityAnalysis,
}

#[pymethods]
impl PySensitivityAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "PoleZeroAnalysis")]
struct PyPoleZeroAnalysis {
    inner: crate::result::PoleZeroAnalysis,
}

#[pymethods]
impl PyPoleZeroAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }

    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "DistortionAnalysis")]
struct PyDistortionAnalysis {
    inner: crate::result::DistortionAnalysis,
}

#[pymethods]
impl PyDistortionAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner
            .base
            .get(name)
            .map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }

    #[getter]
    fn frequency(&self) -> Vec<f64> {
        self.inner.frequency.clone()
    }

    #[getter]
    fn measures(&self) -> HashMap<String, f64> {
        measures_to_dict(&self.inner.base.measures)
    }
}

#[pyclass(name = "PssAnalysis")]
struct PyPssAnalysis {
    inner: crate::result::PssAnalysis,
}

#[pymethods]
impl PyPssAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn time(&self) -> Vec<f64> { self.inner.time.clone() }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.base.measures) }
}

#[pyclass(name = "SParamAnalysis")]
struct PySParamAnalysis {
    inner: crate::result::SParamAnalysis,
}

#[pymethods]
impl PySParamAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn frequency(&self) -> Vec<f64> { self.inner.frequency.clone() }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.base.measures) }
}

#[pyclass(name = "HarmonicBalanceAnalysis")]
struct PyHarmonicBalanceAnalysis {
    inner: crate::result::HarmonicBalanceAnalysis,
}

#[pymethods]
impl PyHarmonicBalanceAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn frequency(&self) -> Vec<f64> { self.inner.frequency.clone() }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.base.measures) }
}

#[pyclass(name = "StabilityAnalysis")]
struct PyStabilityAnalysis {
    inner: crate::result::StabilityAnalysis,
}

#[pymethods]
impl PyStabilityAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn frequency(&self) -> Vec<f64> { self.inner.frequency.clone() }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.base.measures) }
}

#[pyclass(name = "TransientNoiseAnalysis")]
struct PyTransientNoiseAnalysis {
    inner: crate::result::TransientNoiseAnalysis,
}

#[pymethods]
impl PyTransientNoiseAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn time(&self) -> Vec<f64> { self.inner.time.clone() }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.base.measures) }
}

// ── Xyce-specific result bindings ──

#[pyclass(name = "SamplingAnalysis")]
struct PySamplingAnalysis {
    inner: crate::result::SamplingAnalysis,
}

#[pymethods]
impl PySamplingAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.base.measures) }
}

#[pyclass(name = "XyceFftAnalysis")]
struct PyXyceFftAnalysis {
    inner: crate::result::XyceFftAnalysis,
}

#[pymethods]
impl PyXyceFftAnalysis {
    fn __getitem__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyKeyError::new_err(format!("Node '{}' not found", name)))
    }
    fn __getattr__(&self, name: &str) -> PyResult<Vec<f64>> {
        self.inner.base.get(name).map(|wf| wf.data.clone())
            .ok_or_else(|| PyAttributeError::new_err(format!("No node '{}'", name)))
    }
    #[getter]
    fn frequency(&self) -> Vec<f64> { self.inner.frequency.clone() }
    #[getter]
    fn magnitude(&self) -> Vec<f64> { self.inner.magnitude.clone() }
    #[getter]
    fn phase(&self) -> Vec<f64> { self.inner.phase.clone() }
    #[getter]
    fn enob(&self) -> f64 { self.inner.enob }
    #[getter]
    fn sfdr_db(&self) -> f64 { self.inner.sfdr_db }
    #[getter]
    fn snr_db(&self) -> f64 { self.inner.snr_db }
    #[getter]
    fn thd_db(&self) -> f64 { self.inner.thd_db }
    #[getter]
    fn measures(&self) -> HashMap<String, f64> { measures_to_dict(&self.inner.base.measures) }
}

// ── Module-level functions ──

/// Lint a SPICE netlist for common issues and backend-specific warnings.
///
/// Returns a dict with "warnings" and "errors" lists.
#[pyfunction]
#[pyo3(signature = (netlist, backend=None))]
fn lint(netlist: &str, backend: Option<&str>) -> HashMap<String, Vec<HashMap<String, pyo3::PyObject>>> {
    pyo3::Python::with_gil(|py| {
        let result = crate::lint::lint_netlist(netlist, backend);

        let warnings: Vec<HashMap<String, pyo3::PyObject>> = result.warnings.iter().map(|w| {
            let mut map = HashMap::new();
            map.insert("line".to_string(), w.line.into_pyobject(py).unwrap().into_any().unbind());
            map.insert("message".to_string(), w.message.clone().into_pyobject(py).unwrap().into_any().unbind());
            if let Some(ref s) = w.suggestion {
                map.insert("suggestion".to_string(), s.clone().into_pyobject(py).unwrap().into_any().unbind());
            }
            let backends: Vec<String> = w.backends_affected.clone();
            map.insert("backends_affected".to_string(), backends.into_pyobject(py).unwrap().into_any().unbind());
            map
        }).collect();

        let errors: Vec<HashMap<String, pyo3::PyObject>> = result.errors.iter().map(|e| {
            let mut map = HashMap::new();
            map.insert("line".to_string(), e.line.into_pyobject(py).unwrap().into_any().unbind());
            map.insert("message".to_string(), e.message.clone().into_pyobject(py).unwrap().into_any().unbind());
            map
        }).collect();

        let mut out = HashMap::new();
        out.insert("warnings".to_string(), warnings);
        out.insert("errors".to_string(), errors);
        out
    })
}

// ── Module registration ──

fn create_unit_module(m: &Bound<'_, PyModule>) -> PyResult<()> {
    let unit_mod = PyModule::new(m.py(), "unit")?;

    macro_rules! add_unit {
        ($name:ident, $val:expr) => {
            unit_mod.add(stringify!($name), PyUnit { inner: $val })?;
        };
    }

    // Volts
    add_unit!(u_V, u::U_V);
    add_unit!(u_mV, u::U_MV);
    add_unit!(u_uV, u::U_UV);
    // Amperes
    add_unit!(u_A, u::U_A);
    add_unit!(u_mA, u::U_MA);
    add_unit!(u_uA, u::U_UA);
    add_unit!(u_nA, u::U_NA);
    // Ohms
    add_unit!(u_Ohm, u::U_OHM);
    add_unit!(u_kOhm, u::U_KOHM);
    add_unit!(u_MOhm, u::U_MOHM);
    // Farads
    add_unit!(u_F, u::U_F);
    add_unit!(u_mF, u::U_MF);
    add_unit!(u_uF, u::U_UF);
    add_unit!(u_nF, u::U_NF);
    add_unit!(u_pF, u::U_PF);
    add_unit!(u_fF, u::U_FF);
    // Henrys
    add_unit!(u_H, u::U_H);
    add_unit!(u_mH, u::U_MH);
    add_unit!(u_uH, u::U_UH);
    add_unit!(u_nH, u::U_NH);
    // Hertz
    add_unit!(u_Hz, u::U_HZ);
    add_unit!(u_kHz, u::U_KHZ);
    add_unit!(u_MHz, u::U_MHZ);
    add_unit!(u_GHz, u::U_GHZ);
    // Seconds
    add_unit!(u_s, u::U_S);
    add_unit!(u_ms, u::U_MS);
    add_unit!(u_us, u::U_US);
    add_unit!(u_ns, u::U_NS);
    add_unit!(u_ps, u::U_PS);
    // Watts
    add_unit!(u_W, u::U_W);
    add_unit!(u_mW, u::U_MW);
    add_unit!(u_uW, u::U_UW);
    // Degrees
    add_unit!(u_Degree, u::U_DEGREE);

    m.add_submodule(&unit_mod)?;

    // Register in sys.modules so `from pyspice_rs.unit import ...` works
    let sys = m.py().import("sys")?;
    let modules = sys.getattr("modules")?;
    modules.set_item("pyspice_rs.unit", &unit_mod)?;

    Ok(())
}

#[pymodule]
pub fn pyspice_rs(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<PyCircuit>()?;
    m.add_class::<PyUnit>()?;
    m.add_class::<PyUnitValue>()?;
    m.add_class::<PySimulator>()?;
    m.add_class::<PyOperatingPoint>()?;
    m.add_class::<PyDcAnalysis>()?;
    m.add_class::<PyAcAnalysis>()?;
    m.add_class::<PyTransientAnalysis>()?;
    m.add_class::<PyNoiseAnalysis>()?;
    m.add_class::<PyTransferFunctionAnalysis>()?;
    m.add_class::<PySensitivityAnalysis>()?;
    m.add_class::<PyPoleZeroAnalysis>()?;
    m.add_class::<PyDistortionAnalysis>()?;
    // New analysis types
    m.add_class::<PyPssAnalysis>()?;
    m.add_class::<PySParamAnalysis>()?;
    m.add_class::<PyHarmonicBalanceAnalysis>()?;
    m.add_class::<PyStabilityAnalysis>()?;
    m.add_class::<PyTransientNoiseAnalysis>()?;
    // Spectre raw data type
    m.add_class::<PyRawData>()?;
    // Xyce-specific analysis types
    m.add_class::<PySamplingAnalysis>()?;
    m.add_class::<PyXyceFftAnalysis>()?;

    // Module-level functions
    m.add_function(wrap_pyfunction!(lint, m)?)?;

    create_unit_module(m)?;
    Ok(())
}
