//! Pure Model → widget-tree rendering (no I/O, trivially testable).

use schemify_plugin_api::{AlertLevel, ThemeColor, WidgetNode};

use crate::families::PdkFamily;
use crate::installer;
use crate::remote::RemoteBuild;

pub const PANEL: &str = "PDK Config";

/// One row of the version table.
#[derive(Debug, Clone)]
pub struct BuildRow {
    pub hash: String,
    pub date: String,
    pub prerelease: bool,
    pub installed: bool,
    pub enabled: bool,
}

#[derive(Debug, Clone)]
pub enum Phase {
    Idle,
    Downloading {
        file: String,
        asset_idx: usize,
        asset_count: usize,
        bytes: u64,
        total: u64,
    },
    Extracting {
        file: String,
    },
    Done(String),
    Failed(String),
}

pub struct Model {
    /// Remote (or cached) builds per family, newest first.
    pub builds: [Vec<BuildRow>; 3],
    pub selected_tab: usize,
    pub selected_row: Option<usize>,
    pub selected_variant: usize,
    pub full_install: bool,
    pub phase: Phase,
    pub busy: bool,
    pub notice: Option<String>,
}

impl Default for Model {
    fn default() -> Self {
        Self {
            builds: [Vec::new(), Vec::new(), Vec::new()],
            selected_tab: 0,
            selected_row: None,
            selected_variant: 0,
            full_install: false,
            phase: Phase::Idle,
            busy: false,
            notice: None,
        }
    }
}

impl Model {
    pub fn family(&self) -> PdkFamily {
        PdkFamily::ALL[self.selected_tab.min(2)]
    }

    /// Merge a remote listing with on-disk installed/enabled state.
    pub fn set_remote(&mut self, remote: Vec<(PdkFamily, RemoteBuild)>) {
        for (fi, family) in PdkFamily::ALL.into_iter().enumerate() {
            let installed = installer::installed_hashes(family);
            let enabled = installer::enabled_hash(family);
            let mut rows: Vec<BuildRow> = remote
                .iter()
                .filter(|(f, _)| *f == family)
                .map(|(_, b)| BuildRow {
                    installed: installed.contains(&b.hash),
                    enabled: enabled.as_deref() == Some(b.hash.as_str()),
                    hash: b.hash.clone(),
                    date: b.date.clone(),
                    prerelease: b.prerelease,
                })
                .collect();
            // Installed builds missing from the remote list still show up.
            for hash in installed {
                if !rows.iter().any(|r| r.hash == hash) {
                    rows.push(BuildRow {
                        enabled: enabled.as_deref() == Some(hash.as_str()),
                        hash,
                        date: String::new(),
                        prerelease: false,
                        installed: true,
                    });
                }
            }
            self.builds[fi] = rows;
        }
    }

    /// Re-scan installed/enabled flags (after an install).
    pub fn refresh_installed(&mut self) {
        for (fi, family) in PdkFamily::ALL.into_iter().enumerate() {
            let installed = installer::installed_hashes(family);
            let enabled = installer::enabled_hash(family);
            for row in &mut self.builds[fi] {
                row.installed = installed.contains(&row.hash);
                row.enabled = enabled.as_deref() == Some(row.hash.as_str());
            }
        }
    }
}

fn short(hash: &str) -> &str {
    &hash[..8.min(hash.len())]
}

fn mb(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_048_576.0)
}

pub fn render(m: &Model) -> Vec<WidgetNode> {
    let mut w = vec![WidgetNode::Heading("PDK Switcher".into())];

    if let Some(notice) = &m.notice {
        w.push(WidgetNode::Alert {
            level: AlertLevel::Info,
            message: notice.clone(),
        });
    }

    // Family tabs, each with its version table.
    let labels: Vec<String> = PdkFamily::ALL.iter().map(|f| f.name().to_owned()).collect();
    let children: Vec<Vec<WidgetNode>> = PdkFamily::ALL
        .into_iter()
        .enumerate()
        .map(|(fi, _)| {
            let rows = &m.builds[fi];
            if rows.is_empty() {
                return vec![WidgetNode::Label(
                    "No versions known. Press Refresh.".into(),
                )];
            }
            vec![WidgetNode::Table {
                headers: vec!["Version".into(), "Date".into(), "Status".into()],
                rows: rows
                    .iter()
                    .map(|r| {
                        let mut status = String::new();
                        if r.enabled {
                            status.push_str("enabled");
                        } else if r.installed {
                            status.push_str("installed");
                        }
                        if r.prerelease {
                            if !status.is_empty() {
                                status.push(' ');
                            }
                            status.push_str("(pre)");
                        }
                        vec![short(&r.hash).to_owned(), r.date.clone(), status]
                    })
                    .collect(),
                action: Some("select_version".into()),
            }]
        })
        .collect();
    w.push(WidgetNode::Tabs {
        labels,
        selected: m.selected_tab,
        action: "select_tab".into(),
        children,
    });

    // Selected-version controls.
    if let Some(row) = m.selected_row.and_then(|i| m.builds[m.selected_tab].get(i)) {
        let family = m.family();
        let mut controls = vec![WidgetNode::KeyValue {
            entries: vec![
                ["Version".into(), row.hash.clone()],
                ["Date".into(), row.date.clone()],
            ],
        }];
        controls.push(WidgetNode::Dropdown {
            label: "Variant".into(),
            options: family.variants().iter().map(|v| (*v).to_owned()).collect(),
            selected: m.selected_variant,
            action: "select_variant".into(),
        });
        controls.push(WidgetNode::Toggle {
            label: "Install all libraries (bigger download)".into(),
            value: m.full_install,
            action: "toggle_full".into(),
        });
        if !m.busy {
            if row.installed {
                controls.push(WidgetNode::Horizontal {
                    children: vec![
                        WidgetNode::Button {
                            label: if row.enabled {
                                "Re-enable".into()
                            } else {
                                "Enable".into()
                            },
                            action: "enable".into(),
                        },
                        WidgetNode::Button {
                            label: "Use in project".into(),
                            action: "activate".into(),
                        },
                    ],
                });
            } else {
                controls.push(WidgetNode::Button {
                    label: "Install & Enable".into(),
                    action: "install".into(),
                });
            }
        }
        w.push(WidgetNode::Group {
            label: Some(format!("{} {}", family.name(), short(&row.hash))),
            children: controls,
        });
    }

    // Progress / result.
    match &m.phase {
        Phase::Idle => {}
        Phase::Downloading {
            file,
            asset_idx,
            asset_count,
            bytes,
            total,
        } => {
            let frac = if *total > 0 {
                (*bytes as f32 / *total as f32).clamp(0.0, 1.0)
            } else {
                0.0
            };
            w.push(WidgetNode::ProgressBar {
                label: Some(format!("{file} ({}/{asset_count})", asset_idx + 1)),
                value: frac,
                color: None,
            });
            w.push(WidgetNode::KeyValue {
                entries: vec![["Downloaded".into(), format!("{} / {}", mb(*bytes), mb(*total))]],
            });
            w.push(WidgetNode::Button {
                label: "Cancel".into(),
                action: "cancel".into(),
            });
        }
        Phase::Extracting { file } => {
            w.push(WidgetNode::Label(format!("Extracting {file}…")));
        }
        Phase::Done(msg) => w.push(WidgetNode::Alert {
            level: AlertLevel::Success,
            message: msg.clone(),
        }),
        Phase::Failed(msg) => {
            w.push(WidgetNode::Alert {
                level: AlertLevel::Error,
                message: msg.clone(),
            });
            w.push(WidgetNode::Button {
                label: "Retry".into(),
                action: "install".into(),
            });
        }
    }

    w.push(WidgetNode::Separator);
    w.push(WidgetNode::Horizontal {
        children: vec![
            WidgetNode::Button {
                label: "Refresh".into(),
                action: "refresh".into(),
            },
            WidgetNode::Badge {
                text: format!("PDK_ROOT: {}", installer::pdk_root().display()),
                color: Some(ThemeColor::Token("accent".into())),
            },
        ],
    });
    w
}
