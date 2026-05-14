pub mod ngspice;
pub mod xyce;
pub mod ltspice;
pub mod vacask;
pub mod spectre;
pub mod detect;

use crate::result::RawData;
use crate::rawfile;

#[derive(Debug, thiserror::Error)]
pub enum BackendError {
    #[error("No simulator backend found. Install ngspice: sudo apt install ngspice")]
    NoBackend,

    #[error("Analysis '{analysis}' not supported by {backend}.\n\n\
        This analysis requires {required}. Either:\n  \
        1. Install {required}: {install_cmd}\n  \
        2. Alternative: {alternative}")]
    UnsupportedAnalysis {
        analysis: String,
        backend: String,
        required: String,
        install_cmd: String,
        alternative: String,
    },

    #[error("Simulation failed: {0}")]
    SimulationError(String),

    #[error("Raw file parse error: {0}")]
    RawParseError(#[from] rawfile::RawFileError),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Backend trait — each simulator implements this
pub trait Backend: Send + Sync {
    fn name(&self) -> &str;
    fn run(&self, netlist: &str) -> Result<RawData, BackendError>;
}

#[derive(Debug, Clone, PartialEq)]
pub enum BackendKind {
    NgspiceSubprocess,
    NgspiceShared,
    XyceSerial,
    XyceParallel,
    Ltspice {
        executable: std::path::PathBuf,
        use_wine: bool,
    },
    Vacask,
    VacaskShared,
    Spectre,
}

impl BackendKind {
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "ngspice-subprocess" | "ngspice" => Some(Self::NgspiceSubprocess),
            "ngspice-shared" => Some(Self::NgspiceShared),
            "xyce-serial" | "xyce" => Some(Self::XyceSerial),
            "xyce-parallel" => Some(Self::XyceParallel),
            "ltspice" => Some(Self::Ltspice {
                executable: std::path::PathBuf::from("ltspice"),
                use_wine: false,
            }),
            "vacask" => Some(Self::Vacask),
            "vacask-shared" => Some(Self::VacaskShared),
            "spectre" => Some(Self::Spectre),
            _ => None,
        }
    }

    pub fn display_name(&self) -> &str {
        match self {
            Self::NgspiceSubprocess => "ngspice",
            Self::NgspiceShared => "ngspice-shared",
            Self::XyceSerial => "xyce",
            Self::XyceParallel => "xyce-parallel",
            Self::Ltspice { .. } => "ltspice",
            Self::Vacask => "vacask",
            Self::VacaskShared => "vacask-shared",
            Self::Spectre => "spectre",
        }
    }
}

/// Analysis routing preferences — which backends support which analyses
fn analysis_backend_preference(analysis_type: &str) -> &'static [&'static str] {
    match analysis_type {
        // NGSpice-only
        "pz" | "disto" => &["ngspice"],
        // TF: ngspice and ltspice have native .tf, vacask has dcxf, spectre has xf
        "tf" => &["ngspice", "ltspice", "vacask", "spectre"],
        // Harmonic Balance: xyce, vacask, spectre
        "hb" => &["xyce", "vacask", "spectre"],
        // S-parameters
        "sp" | "s_param" => &["xyce", "vacask", "spectre", "ngspice"],
        // Stability (loop gain)
        "stb" | "stability" => &["vacask", "spectre"],
        // PSS
        "pss" => &["spectre", "ngspice"],
        // Transient noise
        "trannoise" => &["vacask"],
        // Xyce-only statistical
        "sampling" | "pce" | "embedded_sampling" => &["xyce"],
        // Xyce-only: transient/adjoint sensitivity
        "sens_tran" | "sens_adjoint" => &["xyce"],
        // AC sensitivity
        "sens_ac" => &["ngspice", "xyce", "spectre"],
        // Spectre-only periodic analyses
        "pac" | "pnoise" | "pxf" | "pstb" | "psp" | "pdisto" |
        "hbac" | "hbnoise" | "hbsp" => &["spectre"],
        // Universal analyses — all backends
        _ => &["ngspice", "xyce", "ltspice", "vacask", "spectre"],
    }
}

/// Auto-detect and select best backend for given analysis type
pub fn detect_and_select(
    analysis_type: &str,
    override_backend: Option<&str>,
) -> Result<Box<dyn Backend>, BackendError> {
    if let Some(name) = override_backend {
        return create_backend_by_name(name, analysis_type);
    }

    let available = detect::detect_backends();
    if available.is_empty() {
        return Err(BackendError::NoBackend);
    }

    let preferences = analysis_backend_preference(analysis_type);

    // Try each preferred backend in order
    for &pref in preferences {
        for kind in available.iter() {
            if kind.display_name().starts_with(pref) {
                return create_backend_from_kind(kind);
            }
        }
    }

    // Fallback: if no preferred backend found, give a helpful error
    if !preferences.is_empty() && preferences[0] != "ngspice" {
        let required = preferences[0];
        let alt = match analysis_type {
            "pz" => ".ac() + post-process for poles/zeros",
            "tf" => ".dc() with small-signal sweep",
            "disto" => ".transient() + FFT post-processing",
            "hb" => "long .tran() + discard startup + FFT",
            "stb" | "stability" => ".ac() + Middlebrook method",
            "pss" => "long .tran() + discard startup",
            "trannoise" => ".tran() with trnoise sources",
            "sampling" | "pce" | "embedded_sampling" => ".control Monte Carlo loops (ngspice)",
            _ => "N/A",
        };
        return Err(BackendError::UnsupportedAnalysis {
            analysis: analysis_type.to_string(),
            backend: available.iter().map(|b| b.display_name()).collect::<Vec<_>>().join(", "),
            required: required.to_string(),
            install_cmd: format!("See docs/backends/{}.md", required),
            alternative: alt.to_string(),
        });
    }

    // Absolute fallback: use first available
    create_backend_from_kind(&available[0])
}

fn create_backend_from_kind(kind: &BackendKind) -> Result<Box<dyn Backend>, BackendError> {
    match kind {
        BackendKind::NgspiceSubprocess => Ok(Box::new(ngspice::NgspiceSubprocess)),
        BackendKind::NgspiceShared => {
            Ok(Box::new(ngspice::NgspiceShared::new()?))
        }
        BackendKind::XyceSerial => Ok(Box::new(xyce::XyceSubprocess { parallel: false })),
        BackendKind::XyceParallel => Ok(Box::new(xyce::XyceSubprocess { parallel: true })),
        BackendKind::Ltspice { executable, use_wine } => Ok(Box::new(ltspice::LtspiceSubprocess {
            executable: executable.clone(),
            use_wine: *use_wine,
            fast_access: false,
        })),
        BackendKind::Vacask => Ok(Box::new(vacask::VacaskSubprocess)),
        BackendKind::VacaskShared => {
            Ok(Box::new(vacask::VacaskLibrary::new()?))
        }
        BackendKind::Spectre => Ok(Box::new(spectre::SpectreSubprocess)),
    }
}

fn create_backend_by_name(name: &str, analysis_type: &str) -> Result<Box<dyn Backend>, BackendError> {
    // Check for analysis compatibility with the requested backend
    let incompatible = match name {
        "xyce" | "xyce-serial" | "xyce-parallel" => {
            matches!(analysis_type, "pz" | "disto")
        }
        "ltspice" => {
            matches!(analysis_type, "pz" | "disto" | "sens" | "sens_ac" | "hb" | "pss" | "stb")
        }
        "vacask" => {
            matches!(analysis_type, "pz" | "disto" | "sens" | "sens_ac" | "dc")
        }
        _ => false,
    };

    if incompatible {
        return Err(BackendError::UnsupportedAnalysis {
            analysis: analysis_type.to_string(),
            backend: name.to_string(),
            required: analysis_backend_preference(analysis_type).first().unwrap_or(&"ngspice").to_string(),
            install_cmd: "See docs/backends/ for installation instructions".to_string(),
            alternative: "See docs/backends/analysis-map.md for emulation strategies".to_string(),
        });
    }

    match name {
        "ngspice-subprocess" | "ngspice" => Ok(Box::new(ngspice::NgspiceSubprocess)),
        "ngspice-shared" => Ok(Box::new(ngspice::NgspiceShared::new()?)),
        "xyce-serial" | "xyce" => Ok(Box::new(xyce::XyceSubprocess { parallel: false })),
        "xyce-parallel" => Ok(Box::new(xyce::XyceSubprocess { parallel: true })),
        "ltspice" => {
            if let Some((exe, wine)) = ltspice::detect_ltspice() {
                Ok(Box::new(ltspice::LtspiceSubprocess { executable: exe, use_wine: wine, fast_access: false }))
            } else {
                Err(BackendError::SimulationError("LTspice not found on this system".to_string()))
            }
        }
        "vacask" => Ok(Box::new(vacask::VacaskSubprocess)),
        "vacask-shared" => Ok(Box::new(vacask::VacaskLibrary::new()?)),
        "spectre" => Ok(Box::new(spectre::SpectreSubprocess)),
        _ => Err(BackendError::SimulationError(format!("Unknown backend: {}", name))),
    }
}
