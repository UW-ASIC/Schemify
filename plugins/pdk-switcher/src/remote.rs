//! Remote version listing: GitHub releases API first, the static
//! fossi-foundation.github.io manifest as a rate-limit fallback, and an
//! on-disk cache so the panel renders offline.

use std::path::PathBuf;

use serde_json::{json, Value};

use crate::families::{parse_tag, PdkFamily};

const RELEASES_API: &str = "https://api.github.com/repos/fossi-foundation/ciel-releases/releases";
const STATIC_MANIFEST: &str = "https://fossi-foundation.github.io/ciel-releases";

/// One remote build of one family.
#[derive(Debug, Clone)]
pub struct RemoteBuild {
    pub hash: String,
    pub date: String,
    pub prerelease: bool,
}

/// One downloadable release asset.
#[derive(Debug, Clone)]
pub struct AssetJob {
    pub filename: String,
    pub url: String,
    pub size: u64,
    pub sha256: Option<String>,
}

pub fn cache_dir() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("schemify/cache/pdk-switcher")
}

fn get_json(url: &str) -> Result<Value, String> {
    let mut response = ureq::get(url)
        .header("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| format!("GET {url}: {e}"))?;
    let body = response
        .body_mut()
        .read_to_string()
        .map_err(|e| e.to_string())?;
    serde_json::from_str(&body).map_err(|e| e.to_string())
}

/// List remote builds for all families. Tries the GitHub API (paged), falls
/// back to the static manifests, then to the local cache. On success the
/// cache is rewritten.
pub fn list_remote() -> Result<Vec<(PdkFamily, RemoteBuild)>, String> {
    let result = list_github().or_else(|api_err| {
        list_static().map_err(|static_err| format!("{api_err}; fallback: {static_err}"))
    });
    match result {
        Ok(builds) => {
            save_cache(&builds);
            Ok(builds)
        }
        Err(e) => match load_cache() {
            Some(builds) => Ok(builds),
            None => Err(e),
        },
    }
}

/// Cached list only (startup path: no network).
pub fn list_cached() -> Vec<(PdkFamily, RemoteBuild)> {
    load_cache().unwrap_or_default()
}

fn list_github() -> Result<Vec<(PdkFamily, RemoteBuild)>, String> {
    let mut builds = Vec::new();
    for page in 1..=3 {
        let v = get_json(&format!("{RELEASES_API}?per_page=100&page={page}"))?;
        let releases = v.as_array().ok_or("releases: expected array")?;
        if releases.is_empty() {
            break;
        }
        for r in releases {
            let Some(tag) = r.get("tag_name").and_then(Value::as_str) else {
                continue;
            };
            let Some((family, hash)) = parse_tag(tag) else {
                continue;
            };
            builds.push((
                family,
                RemoteBuild {
                    hash: hash.to_owned(),
                    date: r
                        .get("created_at")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .chars()
                        .take(10)
                        .collect(),
                    prerelease: r
                        .get("prerelease")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                },
            ));
        }
        if releases.len() < 100 {
            break;
        }
    }
    if builds.is_empty() {
        return Err("GitHub API returned no parsable releases".into());
    }
    Ok(builds)
}

fn list_static() -> Result<Vec<(PdkFamily, RemoteBuild)>, String> {
    let mut builds = Vec::new();
    for family in PdkFamily::ALL {
        let url = format!("{STATIC_MANIFEST}/{}/manifest.json", family.name());
        let Ok(v) = get_json(&url) else {
            continue;
        };
        let Some(versions) = v.get("versions").and_then(Value::as_array) else {
            continue;
        };
        for ver in versions {
            let Some(hash) = ver.get("version").and_then(Value::as_str) else {
                continue;
            };
            builds.push((
                family,
                RemoteBuild {
                    hash: hash.to_owned(),
                    date: ver
                        .get("date")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .chars()
                        .take(10)
                        .collect(),
                    prerelease: ver
                        .get("prerelease")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                },
            ));
        }
    }
    if builds.is_empty() {
        return Err("static manifests unavailable".into());
    }
    Ok(builds)
}

/// Asset list (with sizes + sha256 digests where GitHub provides them) for
/// one build, via the by-tag release endpoint.
pub fn release_assets(family: PdkFamily, hash: &str) -> Result<Vec<AssetJob>, String> {
    let url = format!("{RELEASES_API}/tags/{}-{hash}", family.name());
    let v = get_json(&url)?;
    let assets = v
        .get("assets")
        .and_then(Value::as_array)
        .ok_or("release: no assets array")?;
    let jobs: Vec<AssetJob> = assets
        .iter()
        .filter_map(|a| {
            let name = a.get("name")?.as_str()?;
            if !name.ends_with(".tar.zst") {
                return None;
            }
            Some(AssetJob {
                filename: name.to_owned(),
                url: a.get("browser_download_url")?.as_str()?.to_owned(),
                size: a.get("size").and_then(Value::as_u64).unwrap_or(0),
                sha256: a
                    .get("digest")
                    .and_then(Value::as_str)
                    .and_then(|d| d.strip_prefix("sha256:"))
                    .map(str::to_owned),
            })
        })
        .collect();
    if jobs.is_empty() {
        return Err(format!("no .tar.zst assets in {}-{hash}", family.name()));
    }
    Ok(jobs)
}

// ── Cache ──────────────────────────────────────────────────────────────────

fn cache_file() -> PathBuf {
    cache_dir().join("releases.json")
}

fn save_cache(builds: &[(PdkFamily, RemoteBuild)]) {
    let arr: Vec<Value> = builds
        .iter()
        .map(|(f, b)| {
            json!({
                "family": f.name(),
                "hash": b.hash,
                "date": b.date,
                "prerelease": b.prerelease,
            })
        })
        .collect();
    let _ = std::fs::create_dir_all(cache_dir());
    let _ = std::fs::write(cache_file(), Value::Array(arr).to_string());
}

fn load_cache() -> Option<Vec<(PdkFamily, RemoteBuild)>> {
    let content = std::fs::read_to_string(cache_file()).ok()?;
    let v: Value = serde_json::from_str(&content).ok()?;
    let arr = v.as_array()?;
    let builds: Vec<(PdkFamily, RemoteBuild)> = arr
        .iter()
        .filter_map(|e| {
            Some((
                PdkFamily::from_name(e.get("family")?.as_str()?)?,
                RemoteBuild {
                    hash: e.get("hash")?.as_str()?.to_owned(),
                    date: e.get("date")?.as_str()?.to_owned(),
                    prerelease: e.get("prerelease")?.as_bool()?,
                },
            ))
        })
        .collect();
    if builds.is_empty() {
        None
    } else {
        Some(builds)
    }
}
