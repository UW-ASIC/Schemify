/// SPICE simulator dialect for text emission.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Dialect {
    NgSpice,
    Xyce,
    LtSpice,
    Spectre,
}

impl Dialect {
    /// Whether this dialect uses standard SPICE syntax (dot-commands, prefix letters).
    pub fn is_spice(&self) -> bool {
        matches!(self, Dialect::NgSpice | Dialect::Xyce | Dialect::LtSpice)
    }
}

impl std::fmt::Display for Dialect {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Dialect::NgSpice => write!(f, "ngspice"),
            Dialect::Xyce => write!(f, "Xyce"),
            Dialect::LtSpice => write!(f, "LTspice"),
            Dialect::Spectre => write!(f, "Spectre"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_spice() {
        assert!(Dialect::NgSpice.is_spice());
        assert!(Dialect::Xyce.is_spice());
        assert!(Dialect::LtSpice.is_spice());
        assert!(!Dialect::Spectre.is_spice());
    }

    #[test]
    fn display() {
        assert_eq!(Dialect::NgSpice.to_string(), "ngspice");
        assert_eq!(Dialect::Xyce.to_string(), "Xyce");
        assert_eq!(Dialect::LtSpice.to_string(), "LTspice");
        assert_eq!(Dialect::Spectre.to_string(), "Spectre");
    }
}
