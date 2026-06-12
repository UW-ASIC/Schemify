//! Const tables for the supported PDK families (mirrors ciel's families.py).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PdkFamily {
    Sky130,
    Gf180mcu,
    IhpSg13g2,
}

impl PdkFamily {
    pub const ALL: [PdkFamily; 3] = [Self::Sky130, Self::Gf180mcu, Self::IhpSg13g2];

    /// Release-tag / manifest family name.
    pub fn name(self) -> &'static str {
        match self {
            Self::Sky130 => "sky130",
            Self::Gf180mcu => "gf180mcu",
            Self::IhpSg13g2 => "ihp-sg13g2",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|f| f.name() == name)
    }

    /// On-disk variant directories a build provides (symlinked on enable).
    pub fn variants(self) -> &'static [&'static str] {
        match self {
            Self::Sky130 => &["sky130A", "sky130B"],
            Self::Gf180mcu => &["gf180mcuA", "gf180mcuB", "gf180mcuC", "gf180mcuD"],
            Self::IhpSg13g2 => &["ihp-sg13g2"],
        }
    }

    pub fn default_variant(self) -> &'static str {
        match self {
            Self::Sky130 => "sky130A",
            Self::Gf180mcu => "gf180mcuD",
            Self::IhpSg13g2 => "ihp-sg13g2",
        }
    }

    /// Default library set (ciel's defaults; "Install all" uses the full
    /// release asset list instead).
    pub fn default_assets(self) -> &'static [&'static str] {
        match self {
            Self::Sky130 => &[
                "common",
                "sky130_fd_io",
                "sky130_fd_pr",
                "sky130_fd_sc_hd",
                "sky130_fd_sc_hvl",
                "sky130_ml_xx_hd",
                "sky130_sram_macros",
            ],
            Self::Gf180mcu => &[
                "common",
                "gf180mcu_fd_io",
                "gf180mcu_fd_pr",
                "gf180mcu_fd_sc_mcu7t5v0",
                "gf180mcu_fd_sc_mcu9t5v0",
                "gf180mcu_fd_ip_sram",
            ],
            // Analog-first default: primitives only (common is 330 MB).
            Self::IhpSg13g2 => &["common", "sg13g2_pr"],
        }
    }
}

/// Parse a release tag `{family}-{hash}`; family names contain dashes, so
/// split at the last one.
pub fn parse_tag(tag: &str) -> Option<(PdkFamily, &str)> {
    let (family, hash) = tag.rsplit_once('-')?;
    let family = PdkFamily::from_name(family)?;
    if hash.is_empty() || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some((family, hash))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_and_dashed_tags() {
        let (f, h) = parse_tag("sky130-ff08c23db8359afce3f134c454e7930586d0641c").unwrap();
        assert_eq!(f, PdkFamily::Sky130);
        assert_eq!(h, "ff08c23db8359afce3f134c454e7930586d0641c");

        let (f, h) = parse_tag("ihp-sg13g2-ddb601a4a4473163e1ed6df416b885df18b4ac03").unwrap();
        assert_eq!(f, PdkFamily::IhpSg13g2);
        assert_eq!(h, "ddb601a4a4473163e1ed6df416b885df18b4ac03");
    }

    #[test]
    fn rejects_unknown_family_and_bad_hash() {
        assert!(parse_tag("foo-abc123").is_none());
        assert!(parse_tag("sky130-nothex!").is_none());
        assert!(parse_tag("sky130-").is_none());
    }
}
