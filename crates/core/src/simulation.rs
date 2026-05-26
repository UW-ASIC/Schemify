// ====================================================
// Simulation Results
// BackendAvailability moved to handler state (ADR-001).
// ====================================================

#[derive(Debug, Clone, Default)]
pub struct SimResult {
    pub status: SimStatus,
    pub analysis_type: String,
    pub backend: String,
    pub waveforms: Vec<Waveform>,
    pub measurements: Vec<Measurement>,
    pub node_names: Vec<String>,
    pub op_values: Vec<OpPoint>,
    pub errors: Vec<SimError>,
    pub raw_output: String,
    pub raw_spice: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum SimStatus {
    #[default]
    Success = 0,
    ConvergenceError,
    SyntaxError,
    Timeout,
    BackendNotFound,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct Waveform {
    pub name: String,
    pub x_data: Vec<f64>,
    pub y_data: Vec<f64>,
    pub y_imag: Vec<f64>,
    pub x_unit: String,
    pub y_unit: String,
}

#[derive(Debug, Clone)]
pub struct Measurement {
    pub name: String,
    pub value: f64,
    pub unit: String,
    pub valid: bool,
}

#[derive(Debug, Clone)]
pub struct OpPoint {
    pub node: String,
    pub value: f64,
    pub unit: String,
}

#[derive(Debug, Clone)]
pub struct SimError {
    pub message: String,
    pub line: Option<u32>,
    pub severity: ErrorSeverity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ErrorSeverity {
    Warning = 0,
    Error,
    Fatal,
}

// ====================================================
// Backend Selection
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum SpiceBackend {
    #[default]
    NgSpice = 0,
    Xyce,
    LtSpice,
    Spectre,
}

impl SpiceBackend {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NgSpice => "ngspice",
            Self::Xyce => "xyce",
            Self::LtSpice => "ltspice",
            Self::Spectre => "spectre",
        }
    }

    pub fn from_name(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "ngspice" => Some(Self::NgSpice),
            "xyce" => Some(Self::Xyce),
            "ltspice" => Some(Self::LtSpice),
            "spectre" => Some(Self::Spectre),
            _ => None,
        }
    }
}

// ====================================================
// Stimulus Language (dialect of companion file)
// ====================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum StimulusLang {
    #[default]
    NgSpice = 0,
    Xyce,
    Vacask,
    LtSpice,
    Spectre,
    PySpice,
}

impl StimulusLang {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NgSpice => "ngspice",
            Self::Xyce => "xyce",
            Self::Vacask => "vacask",
            Self::LtSpice => "ltspice",
            Self::Spectre => "spectre",
            Self::PySpice => "pyspice",
        }
    }

    pub fn from_name(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "ngspice" => Some(Self::NgSpice),
            "xyce" => Some(Self::Xyce),
            "vacask" => Some(Self::Vacask),
            "ltspice" => Some(Self::LtSpice),
            "spectre" => Some(Self::Spectre),
            "pyspice" => Some(Self::PySpice),
            _ => None,
        }
    }

    /// File extension for the companion stimulus file.
    pub fn extension(self) -> &'static str {
        match self {
            Self::PySpice => "py",
            _ => "spice",
        }
    }

    /// Whether this is a Python-based stimulus (PySpice).
    pub fn is_python(self) -> bool {
        matches!(self, Self::PySpice)
    }
}
