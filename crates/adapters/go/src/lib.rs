use async_trait::async_trait;
use repoautofix_core::*;
use std::path::{Path, PathBuf};
use tokio::process::Command as TokioCommand;

pub struct GoAdapter {
    go_path: Option<PathBuf>,
    gofmt_path: Option<PathBuf>,
    golangci_lint_path: Option<PathBuf>,
    staticcheck_path: Option<PathBuf>,
}

impl GoAdapter {
    pub fn new() -> Self {
        Self {
            go_path: which::which("go").ok(),
            gofmt_path: which::which("gofmt").ok(),
            golangci_lint_path: which::which("golangci-lint").ok(),
            staticcheck_path: which::which("staticcheck").ok(),
        }
    }

    async fn run_go_vet(&self, project: &Project) -> anyhow::Result<String> {
        let go = self.go_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("go not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(go);
        cmd.current_dir(&project.root)
            .arg("vet")
            .arg("./...");
        
        let output = cmd.output().await?;
        Ok(String::from_utf8_lossy(&output.stderr).to_string()) // go vet outputs to stderr
    }

    async fn run_golangci_lint(&self, project: &Project) -> anyhow::Result<String> {
        let golangci = self.golangci_lint_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("golangci-lint not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(golangci);
        cmd.current_dir(&project.root)
            .arg("run")
            .arg("--out-format=json")
            .arg("./...");
        
        let output = cmd.output().await?;
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_staticcheck(&self, project: &Project) -> anyhow::Result<String> {
        let staticcheck = self.staticcheck_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("staticcheck not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(staticcheck);
        cmd.current_dir(&project.root)
            .arg("-f=json")
            .arg("./...");
        
        let output = cmd.output().await?;
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_gofmt(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let gofmt = self.gofmt_path.as_ref()
            .or_else(|| self.go_path.as_ref().map(|g| g.with_file_name("gofmt")))
            .ok_or_else(|| anyhow::anyhow!("gofmt not found"))?;
        
        let mut cmd = TokioCommand::new(gofmt);
        cmd.current_dir(&project.root)
            .arg("-w")
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("gofmt failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_go_fix(&self, project: &Project) -> anyhow::Result<String> {
        let go = self.go_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("go not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(go);
        cmd.current_dir(&project.root)
            .arg("fix")
            .arg("./...");
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("go fix failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn parse_go_vet_output(&self, output: &str, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut diagnostics = Vec::new();
        
        for line in output.lines() {
            if line.trim().is_empty() {
                continue;
            }
            
            // Format: file:line:col: message
            let parts: Vec<_> = line.splitn(4, ':').collect();
            if parts.len() >= 4 {
                let file = parts[0];
                let line_num = parts[1].parse::<usize>().unwrap_or(1);
                let col = parts[2].parse::<usize>().unwrap_or(1);
                let message = parts[3].trim();
                
                let file_path = project.root.join(file);
                
                let mut diag = Diagnostic::new(
                    file_path,
                    Range {
                        start: Position { line: line_num.saturating_sub(1), column: col.saturating_sub(1) },
                        end: Position { line: line_num.saturating_sub(1), column: col },
                    },
                    Severity::Warning,
                    "go_vet".to_string(),
                    message.to_string(),
                    "go_vet".to_string(),
                );
                diag.tags.push(DiagnosticTag::Style);
                
                diagnostics.push(diag);
            }
        }
        
        Ok(diagnostics)
    }

    fn parse_golangci_output(&self, output: &str, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut diagnostics = Vec::new();
        
        let value: serde_json::Value = serde_json::from_str(output)?;
        
        if let Some(issues) = value.get("Issues").and_then(|v| v.as_array()) {
            for issue in issues {
                let file = issue.get("Pos").and_then(|v| v.get("Filename")).and_then(|v| v.as_str()).unwrap_or("");
                let file_path = project.root.join(file);
                
                let line = issue.get("Pos").and_then(|v| v.get("Line")).and_then(|v| v.as_u64()).unwrap_or(1) as usize;
                let col = issue.get("Pos").and_then(|v| v.get("Column")).and_then(|v| v.as_u64()).unwrap_or(1) as usize;
                
                let code = issue.get("FromLinter").and_then(|v| v.as_str()).unwrap_or("golangci").to_string();
                let message = issue.get("Text").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let severity_str = issue.get("Severity").and_then(|v| v.as_str()).unwrap_or("WARNING");
                
                let severity = match severity_str {
                    "ERROR" => Severity::Error,
                    "WARNING" => Severity::Warning,
                    _ => Severity::Info,
                };
                
                let mut diag = Diagnostic::new(
                    file_path,
                    Range {
                        start: Position { line: line.saturating_sub(1), column: col.saturating_sub(1) },
                        end: Position { line: line.saturating_sub(1), column: col },
                    },
                    severity,
                    code.clone(),
                    message,
                    "golangci-lint".to_string(),
                );
                
                if code.contains("security") || code.contains("gosec") {
                    diag.tags.push(DiagnosticTag::Security);
                } else if code.contains("perf") || code.contains("performance") {
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

impl Default for GoAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LanguageAdapter for GoAdapter {
    fn name(&self) -> &'static str {
        "go"
    }

    fn file_extensions(&self) -> &[&'static str] {
        &["go"]
    }

    fn config_files(&self) -> &[&'static str] {
        &["go.mod", "go.sum", ".golangci.yml", "golangci.yml"]
    }

    async fn is_available(&self) -> bool {
        self.go_path.is_some()
    }

    async fn lint(&self, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut all_diagnostics = Vec::new();
        
        // go vet
        if self.go_path.is_some() {
            let output = self.run_go_vet(project).await?;
            let mut diags = self.parse_go_vet_output(&output, project)?;
            all_diagnostics.append(&mut diags);
        }
        
        // golangci-lint
        if self.golangci_lint_path.is_some() {
            let output = self.run_golangci_lint(project).await?;
            let mut diags = self.parse_golangci_output(&output, project)?;
            all_diagnostics.append(&mut diags);
        }
        
        // staticcheck
        if self.staticcheck_path.is_some() {
            let output = self.run_staticcheck(project).await?;
            // Parse staticcheck JSON
        }
        
        Ok(all_diagnostics)
    }

    async fn lint_file(&self, file: &Path) -> anyhow::Result<Vec<Diagnostic>> {
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        
        if self.go_path.is_some() {
            let go = self.go_path.as_ref().unwrap();
            let mut cmd = TokioCommand::new(go);
            cmd.current_dir(&project.root)
                .arg("vet")
                .arg(file);
            
            let output = cmd.output().await?;
            let stderr = String::from_utf8_lossy(&output.stderr);
            self.parse_go_vet_output(&stderr, &project)
        } else {
            Ok(Vec::new())
        }
    }

    async fn auto_fix(&self, project: &Project, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult> {
        let mut result = FixResult::new();
        
        if self.go_path.is_some() {
            let _output = self.run_go_fix(project).await?;
            
            let remaining = self.lint(project).await?;
            let fixed_count = diagnostics.len().saturating_sub(remaining.len());
            
            for _ in 0..fixed_count {
                result.applied.push(AppliedFix {
                    file: project.root.clone(),
                    diagnostic_code: "go_fix".to_string(),
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
        let _output = self.run_gofmt(project, &["."]).await?;
        
        Ok(FormatResult {
            files_changed: 1,
            files_formatted: vec![project.root.clone()],
            errors: Vec::new(),
        })
    }

    async fn format_file(&self, file: &Path) -> anyhow::Result<FormatResult> {
        let _output = self.run_gofmt(&Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf()), &[file.to_str().unwrap()]).await?;
        
        Ok(FormatResult {
            files_changed: 1,
            files_formatted: vec![file.to_path_buf()],
            errors: Vec::new(),
        })
    }

    fn ai_fix_context(&self, diagnostic: &Diagnostic, file: &Path, project: &Project) -> AiFixContext {
        let content = std::fs::read_to_string(file).unwrap_or_default();
        
        let mut related = Vec::new();
        
        // Test files
        let test_file = file.with_file_name(format!("{}_test.go", file.file_stem().unwrap().to_string_lossy()));
        if test_file.exists() {
            related.push(RelatedFile {
                path: test_file.clone(),
                content: std::fs::read_to_string(&test_file).unwrap_or_default(),
                reason: "test_file".to_string(),
            });
        }
        
        // go.mod
        let config = project.find_config("go.mod")
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|s| serde_json::json!({ "go_mod": s }))
            .unwrap_or(serde_json::json!({}));
        
        AiFixContext {
            diagnostic: diagnostic.clone(),
            file_content: content,
            file_path: file.to_path_buf(),
            related_files: related,
            project_context: ProjectContext {
                language: "go".to_string(),
                config,
                dependencies: Vec::new(),
                test_files: Vec::new(),
            },
            suggested_fix: None,
        }
    }

    async fn version(&self) -> anyhow::Result<String> {
        if let Some(go) = &self.go_path {
            let output = TokioCommand::new(go).arg("version").output().await?;
            return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
        }
        Ok("unknown".to_string())
    }
}