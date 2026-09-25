use async_trait::async_trait;
use repoautofix_core::*;
use std::path::{Path, PathBuf};
use tokio::process::Command as TokioCommand;

pub struct PythonAdapter {
    ruff_path: Option<PathBuf>,
    black_path: Option<PathBuf>,
    pylint_path: Option<PathBuf>,
    mypy_path: Option<PathBuf>,
}

impl PythonAdapter {
    pub fn new() -> Self {
        Self {
            ruff_path: which::which("ruff").ok(),
            black_path: which::which("black").ok(),
            pylint_path: which::which("pylint").ok(),
            mypy_path: which::which("mypy").ok(),
        }
    }

    async fn run_ruff_check(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let ruff = self.ruff_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("ruff not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(ruff);
        cmd.current_dir(&project.root)
            .arg("check")
            .arg("--output-format=json")
            .args(args);
        
        let output = cmd.output().await?;
        
        // ruff returns non-zero on findings
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_ruff_fix(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let ruff = self.ruff_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("ruff not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(ruff);
        cmd.current_dir(&project.root)
            .arg("check")
            .arg("--fix")
            .arg("--output-format=json")
            .args(args);
        
        let output = cmd.output().await?;
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_black(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let black = self.black_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("black not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(black);
        cmd.current_dir(&project.root)
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("black failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_pylint(&self, project: &Project) -> anyhow::Result<String> {
        let pylint = self.pylint_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("pylint not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(pylint);
        cmd.current_dir(&project.root)
            .arg("--output-format=json")
            .arg(".");
        
        let output = cmd.output().await?;
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn parse_ruff_output(&self, output: &str, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut diagnostics = Vec::new();
        
        let value: serde_json::Value = serde_json::from_str(output)?;
        
        if let Some(results) = value.as_array() {
            for result in results {
                let file = result.get("filename").and_then(|v| v.as_str()).unwrap_or("");
                let file_path = project.root.join(file);
                
                let location = result.get("location");
                let row = location.and_then(|v| v.get("row")).and_then(|v| v.as_u64()).unwrap_or(1) as usize;
                let col = location.and_then(|v| v.get("column")).and_then(|v| v.as_u64()).unwrap_or(1) as usize;
                let end_row = location.and_then(|v| v.get("end_row")).and_then(|v| v.as_u64()).unwrap_or(row as u64) as usize;
                let end_col = location.and_then(|v| v.get("end_column")).and_then(|v| v.as_u64()).unwrap_or(col as u64) as usize;
                
                let code = result.get("code").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let message = result.get("message").and_then(|v| v.as_str()).unwrap_or("").to_string();
                
                let severity = if code.starts_with('E') { Severity::Error } 
                    else if code.starts_with('W') { Severity::Warning }
                    else { Severity::Info };
                
                let mut diag = Diagnostic::new(
                    file_path,
                    Range {
                        start: Position { line: row.saturating_sub(1), column: col.saturating_sub(1) },
                        end: Position { line: end_row.saturating_sub(1), column: end_col.saturating_sub(1) },
                    },
                    severity,
                    code.clone(),
                    message,
                    "ruff".to_string(),
                );
                
                if code.contains("SEC") || code.contains("security") {
                    diag.tags.push(DiagnosticTag::Security);
                } else if code.contains("PERF") || code.contains("performance") {
                    diag.tags.push(DiagnosticTag::Performance);
                } else {
                    diag.tags.push(DiagnosticTag::Style);
                }
                
                diagnostics.push(diag);
            }
        }
        
        Ok(diagnostics)
    }
}

impl Default for PythonAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LanguageAdapter for PythonAdapter {
    fn name(&self) -> &'static str {
        "python"
    }

    fn file_extensions(&self) -> &[&'static str] {
        &["py", "pyi", "pyx", "pxd", "pxi"]
    }

    fn config_files(&self) -> &[&'static str] {
        &["pyproject.toml", "ruff.toml", ".ruff.toml", "black.toml", "mypy.ini"]
    }

    async fn is_available(&self) -> bool {
        self.ruff_path.is_some() || self.pylint_path.is_some()
    }

    async fn lint(&self, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut all_diagnostics = Vec::new();
        
        if self.ruff_path.is_some() {
            let output = self.run_ruff_check(project, &["."]).await?;
            let mut diags = self.parse_ruff_output(&output, project)?;
            all_diagnostics.append(&mut diags);
        }
        
        if self.pylint_path.is_some() {
            let output = self.run_pylint(project).await?;
            // Parse pylint JSON output
        }
        
        Ok(all_diagnostics)
    }

    async fn lint_file(&self, file: &Path) -> anyhow::Result<Vec<Diagnostic>> {
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        
        if self.ruff_path.is_some() {
            let output = self.run_ruff_check(&project, &[file.to_str().unwrap()]).await?;
            self.parse_ruff_output(&output, &project)
        } else {
            Ok(Vec::new())
        }
    }

    async fn auto_fix(&self, project: &Project, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult> {
        let mut result = FixResult::new();
        
        if self.ruff_path.is_some() {
            let _output = self.run_ruff_fix(project, &["."]).await?;
            
            let remaining = self.lint(project).await?;
            let fixed_count = diagnostics.len().saturating_sub(remaining.len());
            
            for _ in 0..fixed_count {
                result.applied.push(AppliedFix {
                    file: project.root.clone(),
                    diagnostic_code: "ruff_fixed".to_string(),
                    edit: TextEdit {
                        range: Range { start: Position { line: 0, column: 0 }, end: Position { line: 0, column: 0 } },
                        new_text: String::new(),
                    },
                    before: String::new(),
                    after: String::new(),
                });
            }
            
            result.remaining_diagnostics = remaining;
        } else {
            result.remaining_diagnostics = diagnostics.to_vec();
        }
        
        Ok(result)
    }

    async fn auto_fix_file(&self, file: &Path, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult> {
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        self.auto_fix(&project, diagnostics).await
    }

    async fn format(&self, project: &Project) -> anyhow::Result<FormatResult> {
        if self.ruff_path.is_some() {
            let ruff = self.ruff_path.as_ref().unwrap();
            let mut cmd = TokioCommand::new(ruff);
            cmd.current_dir(&project.root)
                .arg("format")
                .arg(".");
            
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
        } else if self.black_path.is_some() {
            let _output = self.run_black(project, &["."]).await?;
            Ok(FormatResult {
                files_changed: 1,
                files_formatted: vec![project.root.clone()],
                errors: Vec::new(),
            })
        } else {
            Ok(FormatResult {
                files_changed: 0,
                files_formatted: Vec::new(),
                errors: vec![FormatError {
                    file: project.root.clone(),
                    error: "no formatter available (ruff or black)".to_string(),
                }],
            })
        }
    }

    async fn format_file(&self, file: &Path) -> anyhow::Result<FormatResult> {
        if self.ruff_path.is_some() {
            let ruff = self.ruff_path.as_ref().unwrap();
            let mut cmd = TokioCommand::new(ruff);
            cmd.arg("format").arg(file);
            
            let output = cmd.output().await?;
            let formatted = output.status.success();
            
            Ok(FormatResult {
                files_changed: if formatted { 1 } else { 0 },
                files_formatted: if formatted { vec![file.to_path_buf()] } else { Vec::new() },
                errors: Vec::new(),
            })
        } else {
            Ok(FormatResult {
                files_changed: 0,
                files_formatted: Vec::new(),
                errors: vec![FormatError {
                    file: file.to_path_buf(),
                    error: "no formatter available".to_string(),
                }],
            })
        }
    }

    fn ai_fix_context(&self, diagnostic: &Diagnostic, file: &Path, project: &Project) -> AiFixContext {
        let content = std::fs::read_to_string(file).unwrap_or_default();
        
        let mut related = Vec::new();
        
        // Test files
        let test_file = file.with_file_name(format!("test_{}", file.file_name().unwrap().to_string_lossy()));
        if test_file.exists() {
            related.push(RelatedFile {
                path: test_file.clone(),
                content: std::fs::read_to_string(&test_file).unwrap_or_default(),
                reason: "test_file".to_string(),
            });
        }
        
        // Config
        let config = project.find_config("pyproject.toml")
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| toml::from_str(&s).ok())
            .unwrap_or(serde_json::json!({}));
        
        AiFixContext {
            diagnostic: diagnostic.clone(),
            file_content: content,
            file_path: file.to_path_buf(),
            related_files: related,
            project_context: ProjectContext {
                language: "python".to_string(),
                config,
                dependencies: Vec::new(),
                test_files: Vec::new(),
            },
            suggested_fix: None,
        }
    }

    async fn version(&self) -> anyhow::Result<String> {
        if let Some(ruff) = &self.ruff_path {
            let output = TokioCommand::new(ruff).arg("--version").output().await?;
            return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
        }
        Ok("unknown".to_string())
    }
}