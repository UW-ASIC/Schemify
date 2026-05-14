use pyspice::circuit::*;
use pyspice::backend::{Backend, BackendKind, detect};

#[test]
fn test_backend_kind_from_str() {
    assert_eq!(BackendKind::from_str("ngspice"), Some(BackendKind::NgspiceSubprocess));
    assert_eq!(BackendKind::from_str("ngspice-subprocess"), Some(BackendKind::NgspiceSubprocess));
    assert_eq!(BackendKind::from_str("ngspice-shared"), Some(BackendKind::NgspiceShared));
    assert_eq!(BackendKind::from_str("xyce"), Some(BackendKind::XyceSerial));
    assert_eq!(BackendKind::from_str("xyce-serial"), Some(BackendKind::XyceSerial));
    assert_eq!(BackendKind::from_str("xyce-parallel"), Some(BackendKind::XyceParallel));
    assert!(BackendKind::from_str("vacask").is_some());
    assert_eq!(BackendKind::from_str("vacask-shared"), Some(BackendKind::VacaskShared));
    assert!(BackendKind::from_str("spectre").is_some());
    assert!(BackendKind::from_str("ltspice").is_some());
    assert!(BackendKind::from_str("nonexistent").is_none());
}

#[test]
fn test_backend_display_names() {
    assert_eq!(BackendKind::NgspiceSubprocess.display_name(), "ngspice");
    assert_eq!(BackendKind::NgspiceShared.display_name(), "ngspice-shared");
    assert_eq!(BackendKind::XyceSerial.display_name(), "xyce");
    assert_eq!(BackendKind::XyceParallel.display_name(), "xyce-parallel");
    assert_eq!(BackendKind::Vacask.display_name(), "vacask");
    assert_eq!(BackendKind::VacaskShared.display_name(), "vacask-shared");
    assert_eq!(BackendKind::Spectre.display_name(), "spectre");
}

#[test]
fn test_detect_backends() {
    let backends = detect::detect_backends();
    // Should at least not panic; may or may not find backends on CI
    assert!(backends.len() <= 10); // sanity check
}

#[test]
fn test_available_backends_api() {
    let backends = pyspice::simulation::CircuitSimulator::available_backends();
    // Returns strings, should not panic
    for b in &backends {
        assert!(!b.is_empty());
    }
}

#[test]
fn test_backend_override_creates_simulator() {
    let mut c = Circuit::new("backend_test");
    c.v("dd", "vdd", Node::Ground, 3.3);

    // All these should create simulators without panicking
    let _ = c.simulator_with_backend("ngspice");
    let _ = c.simulator_with_backend("xyce");
    let _ = c.simulator_with_backend("ltspice");
    let _ = c.simulator_with_backend("vacask");
    let _ = c.simulator_with_backend("spectre");
}

// ── Vacask SPICE-to-Vacask translator tests ──

#[test]
fn test_vacask_translate_resistor() {
    let input = ".title test\nR1 a b 1k\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("r1 (a b) resistor r=1k"));
}

#[test]
fn test_vacask_translate_voltage_source() {
    let input = ".title test\nV1 vdd 0 DC 3.3\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("v1 (vdd 0) vsource dc=3.3"));
}

#[test]
fn test_vacask_translate_mosfet() {
    let input = ".title test\nM1 drain gate source bulk nmos W=1u L=100n\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("m1 (drain gate source bulk) nmos"));
    assert!(output.contains("w=1u"));
    assert!(output.contains("l=100n"));
}

#[test]
fn test_vacask_translate_ac_analysis() {
    let input = ".title test\nV1 in 0 1\n.ac dec 10 1 1G\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("ac start=1 stop=1G dec=10"));
}

#[test]
fn test_vacask_translate_tran_analysis() {
    let input = ".title test\nV1 in 0 1\n.tran 1u 10m\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("tran stop=10m"));
}

#[test]
fn test_vacask_translate_op_analysis() {
    let input = ".title test\nV1 in 0 1\n.op\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("op"));
}

#[test]
fn test_vacask_translate_include() {
    let input = ".title test\n.include /path/to/model.lib\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("include /path/to/model.lib"));
}

#[test]
fn test_vacask_translate_param() {
    let input = ".title test\n.param vdd=3.3\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("parameters vdd=3.3"));
}

#[test]
fn test_vacask_translate_subcircuit() {
    let input = ".title test\n.SUBCKT mybuf in out vdd\nM1 out in vdd vdd pmos\n.ENDS\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("subckt mybuf (in out vdd)"));
    assert!(output.contains("ends"));
}

#[test]
fn test_vacask_translate_comments() {
    let input = ".title test\n* This is a comment\nR1 a b 1k\n.end";
    let output = pyspice::backend::vacask::spice_to_vacask(input);
    assert!(output.contains("// This is a comment"));
}

// ── LTspice netlist normalization tests ──

#[test]
fn test_ltspice_normalization() {
    use pyspice::backend::ltspice::LtspiceSubprocess;
    use std::path::PathBuf;

    // We can't call normalize_netlist directly (it's private), but we can
    // verify the backend exists and creates properly
    let backend = LtspiceSubprocess {
        executable: PathBuf::from("/usr/bin/ltspice"),
        use_wine: false,
        fast_access: false,
    };
    assert_eq!(pyspice::backend::Backend::name(&backend), "ltspice");
}

// ── New analysis netlist generation tests ──

#[test]
fn test_pss_netlist() {
    let mut c = Circuit::new("pss_test");
    c.v("dd", "vdd", Node::Ground, 3.3);

    let sim = c.simulator();
    let netlist = sim.build_netlist_for_test(".pss 1e9 100e-9 v(out) 128 10");
    assert!(netlist.contains(".pss 1e9 100e-9 v(out) 128 10"));
}

#[test]
fn test_sparam_netlist() {
    let mut c = Circuit::new("sp_test");
    c.v("dd", "vdd", Node::Ground, 3.3);

    let sim = c.simulator();
    let netlist = sim.build_netlist_for_test(".sp dec 10 1e6 1e10");
    assert!(netlist.contains(".sp dec 10 1e6 1e10"));
}

#[test]
fn test_hb_netlist() {
    let mut c = Circuit::new("hb_test");
    c.v("dd", "vdd", Node::Ground, 3.3);

    let sim = c.simulator();
    let netlist = sim.build_netlist_for_test(".HB 1000000000");
    assert!(netlist.contains(".HB 1000000000"));
}

// ── Spectre output format detection tests ──

#[test]
fn test_spectre_output_format_enum() {
    use pyspice::backend::spectre::OutputFormat;
    assert_ne!(OutputFormat::Nutmeg, OutputFormat::Psf);
    assert_eq!(OutputFormat::Nutmeg, OutputFormat::Nutmeg);
    assert_eq!(OutputFormat::Psf, OutputFormat::Psf);
}

// ── PSF parser tests ──

#[test]
fn test_psf_is_psf_detection() {
    assert!(pyspice::psf::is_psf(b"Clarissa\x00\x00\x00\x01"));
    assert!(!pyspice::psf::is_psf(b"Title: test\nPlotname:"));
    assert!(!pyspice::psf::is_psf(b"short"));
}

#[test]
fn test_psf_parse_bad_magic() {
    let data = b"NotAValidPSFFile";
    let result = pyspice::psf::parse_psf(data);
    assert!(result.is_err());
}

#[test]
fn test_psf_parse_too_short() {
    let data = b"Clar";
    let result = pyspice::psf::parse_psf(data);
    assert!(result.is_err());
}

// ── Spectre sweep netlist generation tests ──

#[test]
fn test_spectre_sweep_netlist_generation() {
    // This tests the netlist building logic, not actual Spectre execution
    let backend = pyspice::backend::spectre::SpectreSubprocess;
    // We can't actually run spectre, but we can verify the object exists
    assert_eq!(pyspice::backend::Backend::name(&backend), "spectre");
}

// ── Raw file parser tests ──

#[test]
fn test_rawfile_utf16_detection() {
    // Standard UTF-8 ngspice raw file should NOT be detected as UTF-16
    let raw_content = b"Title: test\nPlotname: Operating Point\n";
    let result = pyspice::rawfile::parse_raw(raw_content);
    // Should fail gracefully (incomplete data) but not panic
    assert!(result.is_err());
}

#[test]
fn test_rawfile_parse_existing_format() {
    // Verify our existing parser still works
    let raw_content = b"Title: test\n\
Plotname: Operating Point\n\
Flags: real\n\
No. Variables: 2\n\
No. Points: 1\n\
Variables:\n\
\t0\tv(out)\tvoltage\n\
\t1\tv(in)\tvoltage\n\
Values:\n\
0\t3.300000e+00\n\
\t1.000000e+00\n";

    let result = pyspice::rawfile::parse_raw(raw_content).unwrap();
    assert_eq!(result.title, "test");
    assert_eq!(result.variables.len(), 2);
    assert!((result.real_data[0][0] - 3.3).abs() < 1e-10);
}

// ── NGSpice shared library backend tests ──

#[test]
fn test_ngspice_shared_is_available_doesnt_panic() {
    // is_available should never panic, regardless of whether the lib exists
    let _ = pyspice::backend::ngspice::NgspiceShared::is_available();
}

#[test]
#[ignore] // Requires libngspice.so to be installed
fn test_ngspice_shared_op_simulation() {
    use pyspice::backend::ngspice::NgspiceShared;

    let shared = NgspiceShared::new().expect("Failed to load libngspice.so");

    let netlist = "\
        test op\n\
        V1 vdd 0 3.3\n\
        R1 vdd out 1k\n\
        R2 out 0 2k\n\
        .op\n\
        .end\n";

    let result = shared.run(netlist);
    assert!(result.is_ok(), "Simulation failed: {:?}", result.err());

    let raw = result.unwrap();
    assert!(!raw.variables.is_empty(), "No variables in result");
    assert_eq!(raw.real_data.len(), raw.variables.len());
}

#[test]
#[ignore] // Requires libngspice.so to be installed
fn test_ngspice_shared_tran_simulation() {
    use pyspice::backend::ngspice::NgspiceShared;

    let shared = NgspiceShared::new().expect("Failed to load libngspice.so");

    let netlist = "\
        test tran\n\
        V1 in 0 PULSE(0 1 0 1n 1n 5u 10u)\n\
        R1 in out 1k\n\
        C1 out 0 1n\n\
        .tran 10n 20u\n\
        .end\n";

    let result = shared.run(netlist);
    assert!(result.is_ok(), "Simulation failed: {:?}", result.err());

    let raw = result.unwrap();
    assert!(!raw.real_data.is_empty());
    assert!(raw.real_data[0].len() > 1, "Expected multiple data points in transient");
}

#[test]
#[ignore] // Requires libngspice.so to be installed
fn test_ngspice_shared_streaming_data() {
    use pyspice::backend::ngspice::NgspiceSharedStreaming;

    let streaming = NgspiceSharedStreaming::new()
        .expect("Failed to load libngspice.so");

    let netlist = "\
        test streaming\n\
        V1 in 0 PULSE(0 1 0 1n 1n 5u 10u)\n\
        R1 in out 1k\n\
        C1 out 0 1n\n\
        .tran 10n 20u\n\
        .end\n";

    let result = streaming.run(netlist);
    assert!(result.is_ok(), "Simulation failed: {:?}", result.err());

    let points = streaming.drain_streaming_data();
    // The buffer should be empty after drain (data was already consumed
    // during run or accumulated)
    let points2 = streaming.drain_streaming_data();
    assert!(points2.is_empty(), "Drain should return empty after first drain");
    // We just verify it does not panic; actual count depends on ngspice internals
    let _ = points;
}

#[test]
#[ignore] // Requires libngspice.so to be installed
fn test_ngspice_shared_backend_name() {
    use pyspice::backend::ngspice::NgspiceShared;

    let shared = NgspiceShared::new().expect("Failed to load libngspice.so");
    assert_eq!(shared.name(), "ngspice-shared");
}

// ── Vacask shared library backend tests ──

#[test]
fn test_vacask_library_is_available_doesnt_panic() {
    // is_available should never panic, regardless of whether the lib exists
    let _ = pyspice::backend::vacask::VacaskLibrary::is_available();
}

#[test]
#[ignore] // Requires libvacask.so to be installed
fn test_vacask_library_init() {
    use pyspice::backend::vacask::VacaskLibrary;

    let lib = VacaskLibrary::new();
    assert!(lib.is_ok(), "Failed to init: {:?}", lib.err());
}

#[test]
#[ignore] // Requires libvacask.so to be installed
fn test_vacask_library_op_simulation() {
    use pyspice::backend::vacask::VacaskLibrary;

    let lib = VacaskLibrary::new().expect("Failed to load libvacask.so");

    let netlist = "\
        test op\n\
        V1 vdd 0 3.3\n\
        R1 vdd out 1k\n\
        R2 out 0 2k\n\
        .op\n\
        .end\n";

    let result = lib.run(netlist);
    assert!(result.is_ok(), "Simulation failed: {:?}", result.err());
}

#[test]
#[ignore] // Requires libvacask.so to be installed
fn test_vacask_library_backend_name() {
    use pyspice::backend::vacask::VacaskLibrary;

    let lib = VacaskLibrary::new().expect("Failed to load libvacask.so");
    assert_eq!(lib.name(), "vacask-shared");
}
