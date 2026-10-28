use async_trait::async_trait;
use std::path::Path;
use crate::{Diagnostic, FixResult, FormatResult, Project, AiFixContext};

#[async_trait]
pub trait LanguageAdapter: Send + Sync {
    fn name(&self) -> &'static str;
    fn file_extensions(&self) -> &[&'static str];
    fn config_files(&self) -> &[&'static str];

    // Check if adapter is available (tools installed)
    async fn is_available(&self) -> bool;

    // Linting
    async fn lint(&self, project: &Project) -> anyhow::Result<Vec<Diagnostic>>;
    async fn lint_file(&self, file: &Path) -> anyhow::Result<Vec<Diagnostic>>;

    // Auto-fix (built-in tooling)
    async fn auto_fix(&self, project: &Project, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult>;
    async fn auto_fix_file(&self, file: &Path, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult>;

    // Formatting
    async fn format(&self, project: &Project) -> anyhow::Result<FormatResult>;
    async fn format_file(&self, file: &Path) -> anyhow::Result<FormatResult>;

    // AI-assisted fix context
    fn ai_fix_context(&self, diagnostic: &Diagnostic, file: &Path, project: &Project) -> AiFixContext;

    // Get version of the tool
    async fn version(&self) -> anyhow::Result<String>;
}

pub struct AdapterRegistry {
    adapters: std::collections::HashMap<String, Box<dyn LanguageAdapter>>,
}

impl AdapterRegistry {
    pub fn new() -> Self {
        Self {
            adapters: std::collections::HashMap::new(),
        }
    }

    pub fn register(&mut self, adapter: Box<dyn LanguageAdapter>) {
        self.adapters.insert(adapter.name().to_string(), adapter);
    }

    pub fn get(&self, name: &str) -> Option<&dyn LanguageAdapter> {
        self.adapters.get(name).map(|b| b.as_ref())
    }

    pub fn get_for_file(&self, file: &Path) -> Option<&dyn LanguageAdapter> {
        let ext = file.extension()?.to_str()?;
        self.adapters.values().find(|a| a.file_extensions().contains(&ext))
    }

    pub fn all(&self) -> Vec<&dyn LanguageAdapter> {
        self.adapters.values().map(|b| b.as_ref()).collect()
    }

    pub fn available_languages(&self) -> Vec<String> {
        self.adapters.keys().cloned().collect()
    }
}

impl Default for AdapterRegistry {
    fn default() -> Self {
        Self::new()
    }
}