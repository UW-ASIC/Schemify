use std::path::PathBuf;

use crate::{MarketplaceError, RegistryIndex, SearchResult};

const INDEX_CACHE_FILE: &str = "registry/index.json";

pub struct Registry {
    url: String,
    cache_dir: PathBuf,
    index: Option<RegistryIndex>,
}

impl Registry {
    pub fn new(registry_url: String, cache_dir: PathBuf) -> Self {
        Self {
            url: registry_url,
            cache_dir,
            index: None,
        }
    }

    pub fn index(&self) -> Option<&RegistryIndex> {
        self.index.as_ref()
    }

    pub fn fetch(&mut self) -> Result<&RegistryIndex, MarketplaceError> {
        let body = match ureq::get(&self.url).call() {
            Ok(mut response) => response
                .body_mut()
                .read_to_string()
                .map_err(|e| MarketplaceError::Network(e.to_string()))?,
            Err(e) => {
                if let Some(cached) = self.load_cached()? {
                    self.index = Some(cached);
                    return Ok(self.index.as_ref().unwrap());
                }
                return Err(MarketplaceError::Network(e.to_string()));
            }
        };

        let index: RegistryIndex = serde_json::from_str(&body)
            .map_err(|e| MarketplaceError::RegistryParse(e.to_string()))?;

        self.write_cache(&body)?;
        self.index = Some(index);
        Ok(self.index.as_ref().unwrap())
    }

    pub fn search(
        &self,
        query: &str,
        installed_ids: &[String],
    ) -> Vec<SearchResult> {
        let Some(index) = &self.index else {
            return Vec::new();
        };
        let query_lower = query.to_lowercase();
        index
            .plugins
            .iter()
            .filter(|entry| {
                query.is_empty()
                    || entry.id.contains(&query_lower)
                    || entry.name.to_lowercase().contains(&query_lower)
                    || entry.description.to_lowercase().contains(&query_lower)
            })
            .map(|entry| SearchResult {
                entry: entry.clone(),
                installed: installed_ids.contains(&entry.id),
            })
            .collect()
    }

    fn cache_path(&self) -> PathBuf {
        self.cache_dir.join(INDEX_CACHE_FILE)
    }

    fn write_cache(&self, body: &str) -> Result<(), MarketplaceError> {
        let path = self.cache_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, body)?;
        Ok(())
    }

    fn load_cached(&self) -> Result<Option<RegistryIndex>, MarketplaceError> {
        let path = self.cache_path();
        if !path.exists() {
            return Ok(None);
        }
        let body = std::fs::read_to_string(&path)?;
        let index: RegistryIndex = serde_json::from_str(&body)
            .map_err(|e| MarketplaceError::RegistryParse(e.to_string()))?;
        Ok(Some(index))
    }

    pub fn load_cached_or_empty(&mut self) -> Result<(), MarketplaceError> {
        if self.index.is_some() {
            return Ok(());
        }
        if let Some(cached) = self.load_cached()? {
            self.index = Some(cached);
        }
        Ok(())
    }

    pub fn find_entry(&self, id: &str) -> Option<&crate::RegistryEntry> {
        self.index
            .as_ref()?
            .plugins
            .iter()
            .find(|e| e.id == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{RegistryEntry, RegistryIndex};
    use std::collections::HashMap;

    fn sample_index() -> RegistryIndex {
        RegistryIndex {
            schema_version: 1,
            updated_at: "2026-06-11".into(),
            plugins: vec![
                RegistryEntry {
                    id: "drc-overlay".into(),
                    name: "DRC Overlay".into(),
                    version: "0.2.1".into(),
                    description: "Design rule check overlay".into(),
                    author: "schemify".into(),
                    license: "MIT".into(),
                    capabilities: vec!["overlays".into()],
                    min_schemify_version: None,
                    homepage: None,
                    downloads: HashMap::new(),
                },
                RegistryEntry {
                    id: "bom-panel".into(),
                    name: "BOM Panel".into(),
                    version: "1.0.0".into(),
                    description: "Bill of materials panel".into(),
                    author: "schemify".into(),
                    license: "MIT".into(),
                    capabilities: vec!["panels".into()],
                    min_schemify_version: None,
                    homepage: None,
                    downloads: HashMap::new(),
                },
            ],
        }
    }

    #[test]
    fn search_by_name() {
        let dir = std::env::temp_dir().join("schemify-test-registry");
        let _ = std::fs::create_dir_all(&dir);
        let mut reg = Registry::new(String::new(), dir);
        reg.index = Some(sample_index());

        let results = reg.search("drc", &[]);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].entry.id, "drc-overlay");
        assert!(!results[0].installed);
    }

    #[test]
    fn search_empty_returns_all() {
        let dir = std::env::temp_dir().join("schemify-test-registry2");
        let _ = std::fs::create_dir_all(&dir);
        let mut reg = Registry::new(String::new(), dir);
        reg.index = Some(sample_index());

        let results = reg.search("", &["bom-panel".into()]);
        assert_eq!(results.len(), 2);
        assert!(results.iter().any(|r| r.entry.id == "bom-panel" && r.installed));
    }

    #[test]
    fn search_by_description() {
        let dir = std::env::temp_dir().join("schemify-test-registry3");
        let _ = std::fs::create_dir_all(&dir);
        let mut reg = Registry::new(String::new(), dir);
        reg.index = Some(sample_index());

        let results = reg.search("bill of materials", &[]);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].entry.id, "bom-panel");
    }
}
