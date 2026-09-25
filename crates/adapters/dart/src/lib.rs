use async_trait::async_trait;
use repoautofix_core::*;
use std::path::{Path, PathBuf};
use std::process::Command;
use tokio::process::Command as TokioCommand;

pub struct DartAdapter {
    dart_path: Option<PathBuf>,
    flutter_path: Option<PathBuf>,
}

impl DartAdapter {
    pub fn new() -> Self {
        Self {
            dart_path: which::which("dart").ok(),
            flutter_path: which::which("flutter").ok(),
        }
    }

    fn has_flutter(&self, project: &Project) -> bool {
        project.find_config("pubspec.yaml").is_some()
    }

    async fn run_dart_analyze(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let dart = self.dart_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("dart not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(dart);
        cmd.current_dir(&project.root)
            .arg("analyze")
            .arg("--format=json")
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() && !output.status.code().map(|c| c == 1).unwrap_or(false) {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("dart analyze failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_dart_fix(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let dart = self.dart_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("dart not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(dart);
        cmd.current_dir(&project.root)
            .arg("fix")
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("dart fix failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    async fn run_dart_format(&self, project: &Project, args: &[&str]) -> anyhow::Result<String> {
        let dart = self.dart_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("dart not found in PATH"))?;
        
        let mut cmd = TokioCommand::new(dart);
        cmd.current_dir(&project.root)
            .arg("format")
            .args(args);
        
        let output = cmd.output().await?;
        
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("dart format failed: {}", stderr));
        }
        
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn parse_dart_analyze_output(&self, output: &str, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let mut diagnostics = Vec::new();
        
        for line in output.lines() {
            if line.trim().is_empty() {
                continue;
            }
            
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(line) {
                if let Some(diag) = self.parse_diagnostic(&value, project) {
                    diagnostics.push(diag);
                }
            }
        }
        
        Ok(diagnostics)
    }

    fn parse_diagnostic(&self, value: &serde_json::Value, project: &Project) -> Option<Diagnostic> {
        let file = value.get("file")?.as_str()?;
        let file_path = project.root.join(file);
        
        let range = value.get("range")?;
        let start_line = range.get("start")?.get("line")?.as_u64()? as usize;
        let start_col = range.get("start")?.get("column")?.as_u64()? as usize;
        let end_line = range.get("end")?.get("line")?.as_u64()? as usize;
        let end_col = range.get("end")?.get("column")?.as_u64()? as usize;
        
        let severity_str = value.get("severity")?.as_str()?;
        let code = value.get("code")?.as_str()?.to_string();
        let message = value.get("message")?.as_str()?.to_string();
        
        let severity = Severity::from_str(severity_str);
        
        Some(Diagnostic::new(
            file_path,
            Range {
                start: Position { line: start_line, column: start_col },
                end: Position { line: end_line, column: end_col },
            },
            severity,
            code,
            message,
            "dart_analyze".to_string(),
        ))
    }
}

impl Default for DartAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl LanguageAdapter for DartAdapter {
    fn name(&self) -> &'static str {
        "dart"
    }

    fn file_extensions(&self) -> &[&'static str] {
        &["dart"]
    }

    fn config_files(&self) -> &[&'static str] {
        &["pubspec.yaml", "analysis_options.yaml"]
    }

    async fn is_available(&self) -> bool {
        self.dart_path.is_some()
    }

    async fn lint(&self, project: &Project) -> anyhow::Result<Vec<Diagnostic>> {
        let output = self.run_dart_analyze(project, &[]).await?;
        self.parse_dart_analyze_output(&output, project)
    }

    async fn lint_file(&self, file: &Path) -> anyhow::Result<Vec<Diagnostic>> {
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        let output = self.run_dart_analyze(&project, &[file.to_str().unwrap()]).await?;
        self.parse_dart_analyze_output(&output, &project)
    }

    async fn auto_fix(&self, project: &Project, diagnostics: &[Diagnostic]) -> anyhow::Result<FixResult> {
        let mut result = FixResult::new();
        
        // Filter auto-fixable diagnostics
        let fixable: Vec<_> = diagnostics.iter()
            .filter(|d| is_auto_fixable_dart(&d.code))
            .collect();
        
        if fixable.is_empty() {
            result.remaining_diagnostics = diagnostics.to_vec();
            return Ok(result);
        }
        
        // Run dart fix --apply
        let output = self.run_dart_fix(project, &["--apply"]).await?;
        
        // Re-lint to see what remains
        let remaining = self.lint(project).await?;
        
        // Calculate what was fixed (simplified)
        let fixed_count = diagnostics.len().saturating_sub(remaining.len());
        
        for _ in 0..fixed_count {
            result.applied.push(AppliedFix {
                file: project.root.clone(),
                diagnostic_code: "auto_fixed".to_string(),
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
        let output = self.run_dart_format(project, &["--set-exit-if-changed"]).await?;
        
        let files_formatted = output.lines()
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
        let project = Project::new(file.parent().unwrap_or(Path::new(".")).to_path_buf());
        let output = self.run_dart_format(&project, &[file.to_str().unwrap()]).await?;
        
        let files_formatted = if output.contains("Formatted") {
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
        
        // Find related files (imports, tests)
        let mut related = Vec::new();
        
        // Add test file if exists
        let test_file = file.with_file_name(format!("{}_test.dart", file.file_stem().unwrap().to_string_lossy()));
        if test_file.exists() {
            related.push(RelatedFile {
                path: test_file.clone(),
                content: std::fs::read_to_string(&test_file).unwrap_or_default(),
                reason: "test_file".to_string(),
            });
        }
        
        AiFixContext {
            diagnostic: diagnostic.clone(),
            file_content: content,
            file_path: file.to_path_buf(),
            related_files: related,
            project_context: ProjectContext {
                language: "dart".to_string(),
                config: serde_json::json!({}),
                dependencies: Vec::new(),
                test_files: Vec::new(),
            },
            suggested_fix: None,
        }
    }

    async fn version(&self) -> anyhow::Result<String> {
        let dart = self.dart_path.as_ref()
            .ok_or_else(|| anyhow::anyhow!("dart not found"))?;
        let output = TokioCommand::new(dart).arg("--version").output().await?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }
}

fn is_auto_fixable_dart(code: &str) -> bool {
    // Dart analyzer codes that support auto-fix
    matches!(code, 
        "unused_import" | 
        "unused_local_variable" | 
        "dead_code" |
        "prefer_const_constructors" |
        "prefer_final_locals" |
        "avoid_redundant_argument_values"
    )
}