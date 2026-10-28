use repoautofix_core::*;
use repoautofix_adapter_dart::DartAdapter;
use repoautofix_adapter_rust::RustAdapter;
use repoautofix_adapter_typescript::TypeScriptAdapter;
use repoautofix_adapter_python::PythonAdapter;
use repoautofix_adapter_go::GoAdapter;
use repoautofix_policy::{PolicyManager, FixConfig, FixReport, FixAction};
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Semaphore;
use tracing::{info, warn, debug};

pub struct FixEngine {
    registry: AdapterRegistry,
    policy: PolicyManager,
    config: FixConfig,
    concurrency_limit: Arc<Semaphore>,
}

impl FixEngine {
    pub fn new(config: FixConfig) -> Self {
        let mut registry = AdapterRegistry::new();
        
        // Register all adapters
        registry.register(Box::new(DartAdapter::new()));
        registry.register(Box::new(RustAdapter::new()));
        registry.register(Box::new(TypeScriptAdapter::new()));
        registry.register(Box::new(PythonAdapter::new()));
        registry.register(Box::new(GoAdapter::new()));
        
        let concurrency = config.max_parallel_files.unwrap_or(4);
        
        Self {
            registry,
            policy: PolicyManager::new(config.policy.clone()),
            config,
            concurrency_limit: Arc::new(Semaphore::new(concurrency)),
        }
    }

    pub fn with_custom_adapters(mut self, adapters: Vec<Box<dyn LanguageAdapter>>) -> Self {
        for adapter in adapters {
            self.registry.register(adapter);
        }
        self
    }

    pub async fn run_fix_cycle(&self, project: &Project) -> anyhow::Result<FixReport> {
        info!("Starting fix cycle for project: {}", project.root.display());
        
        let mut report = FixReport::new();
        report.project_root = project.root.clone();
        
        // Discover files by language
        let files_by_lang = self.discover_files(project)?;
        info!("Found files by language: {:?}", files_by_lang.keys().collect::<Vec<_>>());
        
        // Process each language
        for (lang, files) in files_by_lang {
            if let Some(adapter) = self.registry.get(&lang) {
                info!("Processing {} files for language: {}", files.len(), lang);
                
                let lang_report = self.process_language(adapter, project, &files).await?;
                report.merge_language_report(lang, lang_report);
            } else {
                warn!("No adapter for language: {}", lang);
            }
        }
        
        // Run tests if configured
        if self.config.run_tests {
            info!("Running tests...");
            report.test_results = self.run_tests(project).await?;
        }
        
        info!("Fix cycle complete. Applied: {}, Remaining: {}", 
            report.total_fixes_applied(), report.total_remaining_diagnostics());
        
        Ok(report)
    }

    async fn process_language(
        &self, 
        adapter: &dyn LanguageAdapter, 
        project: &Project, 
        files: &[PathBuf]
    ) -> anyhow::Result<LanguageReport> {
        let _permit = self.concurrency_limit.acquire().await?;
        
        let mut report = LanguageReport::new();
        
        // Check if adapter is available
        if !adapter.is_available().await {
            warn!("Adapter {} not available (tools not installed)", adapter.name());
            report.errors.push(format!("Adapter {} not available", adapter.name()));
            return Ok(report);
        }
        
        // Lint all files
        let diagnostics = adapter.lint(project).await?;
        report.total_diagnostics = diagnostics.len();
        debug!("Found {} diagnostics for {}", diagnostics.len(), adapter.name());
        
        // Categorize by policy
        let (auto_fixable, review_required, ai_candidates, ignored) = 
            self.policy.categorize(&diagnostics);
        
        report.auto_fixable = auto_fixable.len();
        report.review_required = review_required.len();
        report.ai_candidates = ai_candidates.len();
        report.ignored = ignored.len();
        
        // Apply auto-fixes
        if !auto_fixable.is_empty() && !self.config.dry_run {
            let fix_result = adapter.auto_fix(project, &auto_fixable).await?;
            report.fixes_applied = fix_result.total_applied();
            report.fixes_failed = fix_result.total_failed();
            report.remaining_diagnostics = fix_result.remaining_diagnostics;
            
            // Add applied fixes to report
            for fix in fix_result.applied {
                report.applied_fixes.push(AppliedFixInfo {
                    file: fix.file,
                    diagnostic_code: fix.diagnostic_code,
                    action: FixAction::AutoApply,
                });
            }
        } else if !auto_fixable.is_empty() {
            // Dry run - just report what would be fixed
            report.would_fix = auto_fixable.len();
        }
        
        // Format if configured
        if self.config.format && !self.config.dry_run {
            let fmt_result = adapter.format(project).await?;
            report.files_formatted = fmt_result.files_changed;
        }
        
        Ok(report)
    }

    fn discover_files(&self, project: &Project) -> anyhow::Result<HashMap<String, Vec<PathBuf>>> {
        use walkdir::WalkDir;
        
        let mut files_by_lang: HashMap<String, Vec<PathBuf>> = HashMap::new();
        
        for entry in WalkDir::new(&project.root)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
        {
            let path = entry.path();
            
            // Skip hidden directories and common ignore patterns
            if self.should_skip(path) {
                continue;
            }
            
            if let Some(adapter) = self.registry.get_for_file(path) {
                files_by_lang
                    .entry(adapter.name().to_string())
                    .or_default()
                    .push(path.to_path_buf());
            }
        }
        
        Ok(files_by_lang)
    }

    fn should_skip(&self, path: &Path) -> bool {
        let path_str = path.to_string_lossy();
        
        // Skip hidden directories
        if path_str.contains("/.") && !path_str.contains("/.") {
            // Actually check for hidden directories
        }
        
        let skip_patterns = [
            "target/", "build/", "dist/", "node_modules/", ".git/", 
            "__pycache__/", ".venv/", "venv/", ".idea/", ".vscode/",
            "*.lock", "Cargo.lock", "package-lock.json", "yarn.lock",
            "pubspec.lock",
        ];
        
        for pattern in &skip_patterns {
            if path_str.contains(pattern) {
                return true;
            }
        }
        
        false
    }

    async fn run_tests(&self, project: &Project) -> anyhow::Result<TestResults> {
        let mut results = TestResults::new();
        
        // Try to detect and run tests for each language
        for adapter in self.registry.all() {
            if !adapter.is_available().await {
                continue;
            }
            
            match adapter.name() {
                "rust" => {
                    if let Ok(output) = self.run_cargo_test(project).await {
                        results.rust = Some(TestOutput { 
                            passed: output.status.success(),
                            output: String::from_utf8_lossy(&output.stdout).to_string(),
                            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                        });
                    }
                }
                "dart" => {
                    if let Ok(output) = self.run_dart_test(project).await {
                        results.dart = Some(TestOutput { 
                            passed: output.status.success(),
                            output: String::from_utf8_lossy(&output.stdout).to_string(),
                            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                        });
                    }
                }
                "typescript" | "python" | "go" => {
                    // Could add more test runners
                }
                _ => {}
            }
        }
        
        Ok(results)
    }

    async fn run_cargo_test(&self, project: &Project) -> anyhow::Result<tokio::process::Output> {
        let cargo = which::which("cargo")?;
        let mut cmd = tokio::process::Command::new(cargo);
        cmd.current_dir(&project.root).arg("test").arg("--all");
        Ok(cmd.output().await?)
    }

    async fn run_dart_test(&self, project: &Project) -> anyhow::Result<tokio::process::Output> {
        let dart = which::which("dart")?;
        let mut cmd = tokio::process::Command::new(dart);
        cmd.current_dir(&project.root).arg("test");
        Ok(cmd.output().await?)
    }

    pub fn registry(&self) -> &AdapterRegistry {
        &self.registry
    }

    pub fn config(&self) -> &FixConfig {
        &self.config
    }
}

#[derive(Debug, Clone)]
pub struct LanguageReport {
    pub total_diagnostics: usize,
    pub auto_fixable: usize,
    pub review_required: usize,
    pub ai_candidates: usize,
    pub ignored: usize,
    pub would_fix: usize,
    pub fixes_applied: usize,
    pub fixes_failed: usize,
    pub files_formatted: usize,
    pub remaining_diagnostics: Vec<Diagnostic>,
    pub applied_fixes: Vec<AppliedFixInfo>,
    pub errors: Vec<String>,
}

impl LanguageReport {
    pub fn new() -> Self {
        Self {
            total_diagnostics: 0,
            auto_fixable: 0,
            review_required: 0,
            ai_candidates: 0,
            ignored: 0,
            would_fix: 0,
            fixes_applied: 0,
            fixes_failed: 0,
            files_formatted: 0,
            remaining_diagnostics: Vec::new(),
            applied_fixes: Vec::new(),
            errors: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct AppliedFixInfo {
    pub file: PathBuf,
    pub diagnostic_code: String,
    pub action: FixAction,
}