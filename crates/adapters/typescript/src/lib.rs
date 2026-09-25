use async_trait::async_trait;
use repoautofix_core::*;
use std::path::{Path, PathBuf};
use tokio::process::Command as TokioCommand;

pub struct TypeScriptAdapter {
    eslint_path: Option<PathBuf>,
    prettier_path: Option<PathBuf>,
    tsc_path: Option<PathBuf>,
}

impl TypeScriptAdapter {
    pub fn new() -> Self {
        // Try npx first, then direct commands
        Self {
            eslint_path: which::which("npx").ok().or_else(|| which::which("eslint").ok()),
            prettier_path: which::which("npx").ok().or_else(|| which::which("prettier").ok()),
            tsc_path: which::which("npx").ok().or_else(|| which::which("tsc").ok()),
        }
    }

    async fn run_eslint(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let eslint = self.eslint_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("eslint/npx not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(eslint);
        if eslint.file_name() == Some(std::ffi::OsStr::new("npx")) {
            cmd.arg("eslint");
        }
        cmd.current_dir(&project.root)
            .arg("--format=json")
            .args(args);
        
        let output = cmd.output().await?;
        
        // eslint returns non-zero on errors
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_eslint_fix(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let eslint = self.eslint_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("eslint/npx not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(eslint);
        if eslint.file_name() == Some(std::ffi::OsStr::new("npx")) {
            cmd.arg("eslint");
        }
        cmd.current_dir(&project.root)
            .arg("--fix")
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() && output.status.code() != Some(1) {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("eslint --fix failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_prettier(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let prettier = self.prettier_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("prettier/npx not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(prettier);
        if prettier.file_name() == Some(std::ffi::OsStr::new("npx")) {
            cmd.arg("prettier");
        }
        cmd.current_dir(&project.root)
            .arg("--write")
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("prettier failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_tsc(&self, project: &Project) -> anyhow::Result<String> {
        let tsc = self.tsc_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("tsc/npx not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(tsc);
        if tsc.file_name() == Some(std::ffi::OsStr::new("npx")) {
            cmd.arg("tsc");
        }
        cmd.current_dir(&project.root)
            .arg("--noEmit")
            .arg("--pretty=false");
        
        let output = cmd.output().await?;
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn parse_eslint_output(&self, output: &str, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut diagnostics = Vec::new();
        
        let value: serde_json::Value = serde_json::from_str(output)?;
        
        if let Some(results) = value.as_array() {
            for result in results {
                if let Some(file_path) = result.get("filePath").and_then(|v| v.as_str()) {
                    let path = PathBuf::from(file_path);
                    let abs_path = if path.is_absolute() { path } else { project.root.join(path) };
                    
                    if let Some(messages) = result.get("messages").and_then(|v| v.as_array()) {
                        for msg in messages {
                            if let Some(diag) = self.parse_eslint_message(msg, &abs_path) {
                                diagnostics.push(diag);
                            }
                        }
                    }
                }
            }
        }
        
        Ok(diagnostics)
    }

    fn parse_eslint_message(&self, msg: &serde_json::Value, file_path: &Path) -> Option<Diagnostic> {
        let line = msg.get("line")?.as_u64()? as usize;
        let column = msg.get("column")?.as_u64()? as usize;
        let end_line = msg.get("endLine").and_then(|v| v.as_u64()).unwrap_or(line as u64) as usize;
        let end_column = msg.get("endColumn").and_then(|v| v.as_u64()).unwrap_or(column as u64) as usize;
        
        let severity_num = msg.get("severity")?.as_u64()?;
        let severity = match severity_num {
            2 => Severity::Error,
            1 => Severity::Warning,
            _ => Severity::Info,
        };
        
        let rule_id = msg.get("ruleId").and_then(|v| v.as_str()).unwrap_or("unknown").to_string();
        let message = msg.get("message")?.as_str()?.to_string();
        
        let mut diag = Diagnostic::new(
            file_path.to_path_buf(),
            Range {
                start: Position { line: line.saturating_sub(1), column: column.saturating_sub(1) },
                end: Position { line: end_line.saturating_sub(1), column: end_column.saturating_sub(1) },
            },
            severity,
            rule_id.clone(),
            message,
            "eslint".to_string(),
        );
        
        if rule_id.contains("security") {
            diag.tags.push(DiagnosticTag::Security);
        } else if rule_id.contains("perf") || rule_id.contains("performance") {
            diag.tags.push(DiagnosticTag::Performance);
        } else {
            diag.tags.push(DiagnosticTag::Style);
        }
        
        Some(diag)
    }
}

impl Default for TypeScriptAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LanguageAdapter for TypeScriptAdapter {
    fn name(&self) -> &'static str {
        "typescript"
    }

    fn file_extensions(&self) -> &[&'static str] {
        &["ts", "tsx", "js", "jsx", "mjs", "cjs"]
    }

    fn config_files(&self) -> &[&'static str] {
        &["package.json", "tsconfig.json", "eslint.config.js", ".eslintrc.js", "prettier.config.js"]
    }

    async fn is_available(&self) -> bool {
        self.eslint_path.is_some() || self.tsc_path.is_some()
    }

    async fn lint(&self, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut all_diagnostics = Vec::new();
        
        // ESLint
        if self.eslint_path.is_some() {
            let output = self.run_eslint(project, &["."]).await?;
            let mut diags = self.parse_eslint_output(&output, project)?;
            all_diagnostics.append(&mut diags);
        }
        
        // TypeScript compiler
        if self.tsc_path.is_some() {
            let output = self.run_tsc(project).await?;
            // Parse tsc output (simplified)
            for line in output.lines() {
                if line.contains(": error TS") || line.contains(": warning TS") {
                    // Could parse more carefully
                }
            }
        }
        
        Ok(all_diagnostics)
    }

    async fn lint_file(&self, file: &Path) -> anyhow::Result<Vec<Diagnostic>> {
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        
        if self.eslint_path.is_some() {
            let output = self.run_eslint(&project, &[file.to_str().unwrap()]).await?;
            self.parse_eslint_output(&output, &project)
        } else {
            Ok(Vec::new())
        }
    }

    async fn auto_fix(&self, project: &Project, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult> {
        let mut result = FixResult::new();
        
        // ESLint --fix handles most fixable rules
        if self.eslint_path.is_some() {
            let _output = self.run_eslint_fix(project, &["."]).await?;
            
            let remaining = self.lint(project).await?;
            let fixed_count = diagnostics.len().saturating_sub(remaining.len());
            
            for _ in 0..fixed_count {
                result.applied.push(AppliedFix {
                    file: project.root.clone(),
                    diagnostic_code: "eslint_fixed".to_string(),
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
        if self.prettier_path.is_some() {
            let output = self.run_prettier(project, &["."]).await?;
            
            let files_formatted = output.lines()
                .filter(|l| !l.trim().is_empty())
                .map(|l| project.root.join(l.trim()))
                .collect();
            
            Ok(FormatResult {
                files_changed: files_formatted.len(),
                files_formatted,
                errors: Vec::new(),
            })
        } else {
            Ok(FormatResult {
                files_changed: 0,
                files_formatted: Vec::new(),
                errors: vec![FormatError {
                    file: project.root.clone(),
                    error: "prettier not available".to_string(),
                }],
            })
        }
    }

    async fn format_file(&self, file: &Path) -> anyhow::Result<FormatResult> {
        if self.prettier_path.is_some() {
            let output = self.run_prettier(&Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf()), &[file.to_str().unwrap()]).await?;
            
            let files_formatted = if output.contains(file.to_str().unwrap_or("")) {
                vec![file.to_path_buf()]
            } else {
                Vec::new()
            };
            
            Ok(FormatResult {
                files_changed: files_formatted.len(),
                files_formatted,
                errors: Vec::new(),
            })
        } else {
            Ok(FormatResult {
                files_changed: 0,
                files_formatted: Vec::new(),
                errors: vec![FormatError {
                    file: file.to_path_buf(),
                    error: "prettier not available".to_string(),
                }],
            })
        }
    }

    fn ai_fix_context(&self, diagnostic: &Diagnostic, file: &Path, project: &Project) -> AiFixContext {
        let content = std::fs::read_to_string(file).unwrap_or_default();
        
        let mut related = Vec::new();
        
        // Test files
        for ext in &["test.ts", "test.js", "spec.ts", "spec.js"] {
            let test_file = file.with_file_name(format!("{}.{}", file.file_stem().unwrap().to_string_lossy(), ext));
            if test_file.exists() {
                related.push(RelatedFile {
                    path: test_file.clone(),
                    content: std::fs::read_to_string(&test_file).unwrap_or_default(),
                    reason: "test_file".to_string(),
                });
            }
        }
        
        // Config
        let config = project.find_config("package.json")
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(serde_json::json!({}));
        
        AiFixContext {
            diagnostic: diagnostic.clone(),
            file_content: content,
            file_path: file.to_path_buf(),
            related_files: related,
            project_context: ProjectContext {
                language: "typescript".to_string(),
                config,
                dependencies: Vec::new(),
                test_files: Vec::new(),
            },
            suggested_fix: None,
        }
    }

    async fn version(&self) -> anyhow::Result<String> {
        if let Some(eslint) = &self.eslint_path {
            let mut cmd = TokioCommand::new(eslint);
            if eslint.file_name() == Some(std::ffi::OsStr::new("npx")) {
                cmd.arg("eslint");
            }
            cmd.arg("--version");
            let output = cmd.output().await?;
            return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
        }
        Ok("unknown".to_string())
    }
}