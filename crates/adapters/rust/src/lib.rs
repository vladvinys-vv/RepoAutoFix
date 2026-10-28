use async_trait::async_trait;
use repoautofix_core::*;
use std::path::{Path, PathBuf};
use tokio::process::Command as TokioCommand;

pub struct RustAdapter {
    cargo_path: Option<PathBuf>,
    rustfmt_path: Option<PathBuf>,
}

impl RustAdapter {
    pub fn new() -> Self {
        Self {
            cargo_path: which::which("cargo").ok(),
            rustfmt_path: which::which("rustfmt").ok(),
        }
    }

    async fn run_cargo_clippy(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let cargo = self.cargo_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("cargo not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(cargo);
        cmd.current_dir(&project.root)
            .arg("clippy")
            .arg("--message-format=json")
            .arg("--")
            .arg("-D")
            .arg("warnings")
            .args(args);
        
        let output = cmd.output().await?;
        
        // clippy returns non-zero on warnings, that's OK
        let stdout = String::from_utf8_lossy(&output.stdout);
        Ok(stdout.to_string())
    }

    async fn run_cargo_fix(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let cargo = self.cargo_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("cargo not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(cargo);
        cmd.current_dir(&project.root)
            .arg("fix")
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("cargo fix failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_rustfmt(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let rustfmt = self.rustfmt_path.as_ref()
            .or_else(|| self.cargo_path.as_ref().map(|c| c.with_file_name("rustfmt")))
            .ok_or_else(|| anyhow::anyhow!("rustfmt not found"))?;
        
        let mut cmd = TokioCommand::new(rustfmt);
        cmd.current_dir(&project.root)
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("rustfmt failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_cargo_check(&self, project: &Project) -> anyhow::Result<String> {
        let cargo = self.cargo_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("cargo not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(cargo);
        cmd.current_dir(&project.root)
            .arg("check")
            .arg("--message-format=json");
        
        let output = cmd.output().await?;
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn parse_clippy_output(&self, output: &str, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut diagnostics = Vec::new();
        
        for line in output.lines() {
            if line.trim().is_empty() {
                continue;
            }
            
            if let Ok(msg) = serde_json::from_str::<serde_json::Value>(line) {
                if msg.get("reason").and_then(|v| v.as_str()) == Some("compiler-message") {
                    if let Some(diag) = self.parse_clippy_diagnostic(&msg, project) {
                        diagnostics.push(diag);
                    }
                }
            }
        }
        
        Ok(diagnostics)
    }

    fn parse_clippy_diagnostic(&self, msg: &serde_json::Value, project: &Project) -> Option<Diagnostic> {
        let message = msg.get("message")?;
        let file = message.get("spans")?.get(0)?.get("file_name")?.as_str()?;
        let file_path = project.root.join(file);
        
        let span = message.get("spans")?.get(0)?;
        let start_line = span.get("line_start")?.as_u64()? as usize;
        let start_col = span.get("column_start")?.as_u64()? as usize;
        let end_line = span.get("line_end")?.as_u64()? as usize;
        let end_col = span.get("column_end")?.as_u64()? as usize;
        
        let level = message.get("level")?.as_str()?;
        let code = message.get("code")?.get("code")?.as_str()?.to_string();
        let text = message.get("message")?.as_str()?.to_string();
        
        let severity = match level {
            "error" => Severity::Error,
            "warning" => Severity::Warning,
            "note" | "help" => Severity::Info,
            _ => Severity::Warning,
        };
        
        let mut diag = Diagnostic::new(
            file_path,
            Range {
                start: Position { line: start_line, column: start_col },
                end: Position { line: end_line, column: end_col },
            },
            severity,
            code.clone(),
            text,
            "clippy".to_string(),
        );
        
        // Add tags based on code
        if code.contains("security") || code.contains("unsafe") {
            diag.tags.push(DiagnosticTag::Security);
        }
        if code.contains("perf") || code.contains("performance") {
            diag.tags.push(DiagnosticTag::Performance);
        }
        if code.contains("style") || code.contains("clippy::") {
            diag.tags.push(DiagnosticTag::Style);
        }
        
        Some(diag)
    }
}

impl Default for RustAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LanguageAdapter for RustAdapter {
    fn name(&self) -> &'static str {
        "rust"
    }

    fn file_extensions(&self) -> &[&'static str] {
        &["rs"]
    }

    fn config_files(&self) -> &[&'static str] {
        &["Cargo.toml", "rustfmt.toml", "clippy.toml"]
    }

    async fn is_available(&self) -> bool {
        self.cargo_path.is_some()
    }

    async fn lint(&self, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let output = self.run_cargo_clippy(project, &[]).await?;
        self.parse_clippy_output(&output, project)
    }

    async fn lint_file(&self, file: &Path) -> anyhow::Result<Vec<Diagnostic>> {
        // For single file, we need a minimal Cargo project or use rust-analyzer
        // Simplified: just check the whole project
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        self.lint(&project).await
    }

    async fn auto_fix(&self, project: &Project, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult> {
        let mut result = FixResult::new();
        
        // Filter auto-fixable (clippy supports --fix for many lints)
        let fixable: Vec<_> = diagnostics.iter()
            .filter(|d| is_auto_fixable_rust(&d.code))
            .collect();
        
        if fixable.is_empty() {
            result.remaining_diagnostics = diagnostics.to_vec();
            return Ok(result);
        }
        
        // Run cargo fix
        let output = self.run_cargo_fix(project, &["--allow-dirty", "--allow-staged"]).await?;
        
        // Re-lint
        let remaining = self.lint(project).await?;
        
        let fixed_count = diagnostics.len().saturating_sub(remaining.len());
        
        for _ in 0..fixed_count {
            result.applied.push(AppliedFix {
                file: project.root.clone(),
                diagnostic_code: "clippy_fixed".to_string(),
                edit: TextEdit {
                    range: Range { start: Position { line: 0, column: 0 }, end: Position { line: 0, column: 0 } },
                    new_text: String::new(),
                },
                before: String::new(),
                after: String::new(),
            });
        }
        
        result.remaining_diagnostics = remaining;
        
        Ok(result)
    }

    async fn auto_fix_file(&self, file: &Path, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult> {
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        self.auto_fix(&project, diagnostics).await
    }

    async fn format(&self, project: &Project) -> anyhow::Result<FormatResult> {
        // Use cargo fmt
        let cargo = self.cargo_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("cargo not found"))?;
        
        let mut cmd = TokioCommand::new(cargo);
        cmd.current_dir(&project.root)
            .arg("fmt")
            .arg("--all");
        
        let output = cmd.output().await?;
        
        let stdout = String::from_utf8_lossy(&output.stdout);
        let files_formatted = stdout.lines()
            .filter(|l| l.contains("Formatted"))
            .map(|l| {
                let parts: Vec<_> = l.split_whitespace().collect();
                project.root.join(parts.last().unwrap_or(""))
            })
            .collect();
        
        Ok(FormatResult {
            files_changed: files_formatted.len(),
            files_formatted,
            errors: Vec::new(),
        })
    }

    async fn format_file(&self, file: &Path) -> anyhow::Result<FormatResult> {
        let rustfmt = self.rustfmt_path.as_ref()
            .or_else(|| self.cargo_path.as_ref().map(|c| c.with_file_name("rustfmt")))
            .ok_or_else(|| anyhow::anyhow!("rustfmt not found"))?;
        
        let mut cmd = TokioCommand::new(rustfmt);
        cmd.arg(file);
        
        let output = cmd.output().await?;
        
        let files_formatted = if output.status.success() {
            vec![file.to_path_buf()]
        } else {
            Vec::new()
        };
        
        Ok(FormatResult {
            files_changed: files_formatted.len(),
            files_formatted,
            errors: Vec::new(),
        })
    }

    fn ai_fix_context(&self, diagnostic: &Diagnostic, file: &Path, project: &Project) -> AiFixContext {
        let content = std::fs::read_to_string(file).unwrap_or_default();
        
        let mut related = Vec::new();
        
        // Find test files
        let test_file = file.with_file_name(format!("{}_test.rs", file.file_stem().unwrap().to_string_lossy()));
        if test_file.exists() {
            related.push(RelatedFile {
                path: test_file.clone(),
                content: std::fs::read_to_string(&test_file).unwrap_or_default(),
                reason: "test_file".to_string(),
            });
        }
        
        // Parse Cargo.toml for context
        let cargo_toml = project.root.join("Cargo.toml");
        let config = if cargo_toml.exists() {
            std::fs::read_to_string(&cargo_toml)
                .ok()
                .and_then(|s| toml::from_str(&s).ok())
                .unwrap_or(serde_json::json!({}))
        } else {
            serde_json::json!({})
        };
        
        AiFixContext {
            diagnostic: diagnostic.clone(),
            file_content: content,
            file_path: file.to_path_buf(),
            related_files: related,
            project_context: ProjectContext {
                language: "rust".to_string(),
                config,
                dependencies: Vec::new(),
                test_files: Vec::new(),
            },
            suggested_fix: None,
        }
    }

    async fn version(&self) -> anyhow::Result<String> {
        let cargo = self.cargo_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("cargo not found"))?;
        let output = TokioCommand::new(cargo).arg("--version").output().await?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }
}

fn is_auto_fixable_rust(code: &str) -> bool {
    // Many clippy lints support auto-fix
    code.starts_with("clippy::") && !code.contains("nursery") && !code.contains("cargo")
}