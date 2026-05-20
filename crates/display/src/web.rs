#![cfg(target_arch = "wasm32")]

use std::collections::HashMap;
use serde::Deserialize;

/// Bundled project data fetched from project.json at startup.
#[derive(Debug, Deserialize)]
pub struct ProjectBundle {
    pub name: String,
    #[serde(default)]
    pub pdk: Option<String>,
    #[serde(default)]
    pub plugins: Vec<String>,
    /// Map of relative path -> file content.
    pub files: HashMap<String, String>,
}

/// Fetch and parse project.json from the same origin as the WASM app.
pub async fn fetch_project_bundle() -> Result<ProjectBundle, String> {
    use wasm_bindgen::JsCast;
    use wasm_bindgen_futures::JsFuture;

    let window = web_sys::window().ok_or("no window")?;
    let resp_value = JsFuture::from(window.fetch_with_str("project.json"))
        .await
        .map_err(|e| format!("fetch failed: {e:?}"))?;
    let resp: web_sys::Response = resp_value
        .dyn_into()
        .map_err(|_| "response cast failed")?;

    if !resp.ok() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let text = JsFuture::from(
        resp.text().map_err(|_| "text() failed")?,
    )
    .await
    .map_err(|e| format!("text await failed: {e:?}"))?;

    let json_str = text
        .as_string()
        .ok_or("response not a string")?;

    serde_json::from_str(&json_str)
        .map_err(|e| format!("JSON parse error: {e}"))
}
