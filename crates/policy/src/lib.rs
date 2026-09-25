use repoautofix_core::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use regex::Regex;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Policy {
    pub rules: Vec<PolicyRule>,
    pub global: GlobalPolicy,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            rules: vec![
                // Auto-apply safe fixes
                PolicyRule {
                    pattern: r"unused_import".to_string(),
                    languages: vec![],
                    action: FixAction::AutoApply,
                    min_severity: Severity::Hint,
                    max_severity: Severity::Warning,
                },
                PolicyRule {
                    pattern: r"dead_code".to_string(),
                    languages: vec![],
                    action: FixAction::RequireReview,
                    min_severity: Severity::Hint,
                    max_severity: Severity::Warning,
                },
                PolicyRule {
                    pattern: r"prefer_const".to_string(),
                    languages: vec!["dart".to_string()],
                    action: FixAction::AutoApply,
                    min_severity: Severity::Hint,
                    max_severity: Severity::Info,
                },
                // Require review for potentially risky changes
                PolicyRule {
                    pattern: r"clippy::unwrap_used".to_string(),
                    languages: vec!["rust".to_string()],
                    action: FixAction::AiAssist,
                    min_severity: Severity::Warning,
                    max_severity: Severity::Error,
                },
                PolicyRule {
                    pattern: r"clippy::expect_used".to_string(),
                    languages: vec!["rust".to_string()],
                    action: FixAction::AiAssist,
                    min_severity: Severity::Warning,
                    max_severity: Severity::Error,
                },
                // Security issues require review
                PolicyRule {
                    pattern: r"security".to_string(),
                    languages: vec![],
                    action: FixAction::RequireReview,
                    min_severity: Severity::Warning,
                    max_severity: Severity::Error,
                },
                // Performance suggestions go to AI
                PolicyRule {
                    pattern: r"perf|performance".to_string(),
                    languages: vec![],
                    action: FixAction::AiAssist,
                    min_severity: Severity::Hint,
                    max_severity: Severity::Warning,
                },
                // Style issues auto-apply
                PolicyRule {
                    pattern: r"style".to_string(),
                    languages: vec![],
                    action: FixAction::AutoApply,
                    min_severity: Severity::Hint,
                    max_severity: Severity::Info,
                },
            ],
            global: GlobalPolicy::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyRule {
    pub pattern: String,
    pub languages: Vec<String>,
    pub action: FixAction,
    pub min_severity: Severity,
    pub max_severity: Severity,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum FixAction {
    AutoApply,
    RequireReview,
    AiAssist,
    Ignore,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalPolicy {
    pub max_files_per_run: usize,
    pub max_edits_per_file: usize,
    pub require_tests_pass: bool,
    pub require_clean_git: bool,
    pub allowed_ai_providers: Vec<String>,
    pub dry_run_default: bool,
}

impl Default for GlobalPolicy {
    fn default() -> Self {
        Self {
            max_files_per_run: 50,
            max_edits_per_file: 20,
            require_tests_pass: true,
            require_clean_git: true,
            allowed_ai_providers: vec!["anthropic".to_string(), "openai".to_string()],
            dry_run_default: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixConfig {
    pub policy: Policy,
    pub enable_ai: bool,
    pub format: bool,
    pub run_tests: bool,
    pub dry_run: bool,
    pub max_parallel_files: Option<usize>,
    pub fail_on_remaining: bool,
}

impl Default for FixConfig {
    fn default() -> Self {
        Self {
            policy: Policy::default(),
            enable_ai: false,
            format: true,
            run_tests: true,
            dry_run: true,
            max_parallel_files: Some(4),
            fail_on_remaining: false,
        }
    }
}

pub struct PolicyManager {
    policy: Policy,
    compiled_rules: Vec<CompiledRule>,
}

#[derive(Debug)]
struct CompiledRule {
    regex: Regex,
    rule: PolicyRule,
}

impl PolicyManager {
    pub fn new(policy: Policy) -> Self {
        let compiled_rules = policy.rules.iter()
            .filter_map(|rule| {
                Regex::new(&rule.pattern).ok().map(|regex| CompiledRule { regex, rule: rule.clone() })
            })
            .collect();
        
        Self {
            policy,
            compiled_rules,
        }
    }

    pub fn categorize(&self, diagnostics: &[Diagnostic]) -> (Vec<Diagnostic>, Vec<Diagnostic>, Vec<Diagnostic>, Vec<Diagnostic>) {
        let mut auto_fixable = Vec::new();
        let mut review_required = Vec::new();
        let mut ai_candidates = Vec::new();
        let mut ignored = Vec::new();
        
        for diag in diagnostics {
            let action = self.get_action(diag);
            
            match action {
                FixAction::AutoApply => auto_fixable.push(diag.clone()),
                FixAction::RequireReview => review_required.push(diag.clone()),
                FixAction::AiAssist => ai_candidates.push(diag.clone()),
                FixAction::Ignore => ignored.push(diag.clone()),
            }
        }
        
        (auto_fixable, review_required, ai_candidates, ignored)
    }

    fn get_action(&self, diagnostic: &Diagnostic) -> FixAction {
        for compiled in &self.compiled_rules {
            let rule = &compiled.rule;
            
            // Check language match
            if !rule.languages.is_empty() && !rule.languages.contains(&diagnostic.source) {
                continue;
            }
            
            // Check pattern match
            if !compiled.regex.is_match(&diagnostic.code) && !compiled.regex.is_match(&diagnostic.message) {
                continue;
            }
            
            // Check severity range
            let sev_order = |s: &Severity| match s {
                Severity::Hint => 0,
                Severity::Info => 1,
                Severity::Warning => 2,
                Severity::Error => 3,
            };
            
            let diag_sev = sev_order(&diagnostic.severity);
            let min_sev = sev_order(&rule.min_severity);
            let max_sev = sev_order(&rule.max_severity);
            
            if diag_sev < min_sev || diag_sev > max_sev {
                continue;
            }
            
            return rule.action.clone();
        }
        
        // Default: require review for errors, auto-apply for hints
        match diagnostic.severity {
            Severity::Error => FixAction::RequireReview,
            Severity::Warning => FixAction::RequireReview,
            Severity::Info => FixAction::AutoApply,
            Severity::Hint => FixAction::AutoApply,
        }
    }

    pub fn validate_plan(&self, plan: &FixPlan) -> anyhow::Result<()> {
        let global = &self.policy.global;
        
        if plan.files.len() > global.max_files_per_run {
            anyhow::bail!("Plan exceeds max files per run: {} > {}", plan.files.len(), global.max_files_per_run);
        }
        
        for file_plan in &plan.files {
            if file_plan.edits.len() > global.max_edits_per_file {
                anyhow::bail!("File {} exceeds max edits per file: {} > {}", 
                    file_plan.file.display(), file_plan.edits.len(), global.max_edits_per_file);
            }
        }
        
        if global.require_clean_git {
            // Check git status
            let output = std::process::Command::new("git")
                .args(["status", "--porcelain"])
                .current_dir(&plan.project_root)
                .output()?;
            
            if !output.stdout.is_empty() {
                anyhow::bail!("Working directory not clean (require_clean_git=true)");
            }
        }
        
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct FixPlan {
    pub project_root: PathBuf,
    pub files: Vec<FileFixPlan>,
}

#[derive(Debug, Clone)]
pub struct FileFixPlan {
    pub file: PathBuf,
    pub edits: Vec<repoautofix_core::TextEdit>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixReport {
    pub project_root: PathBuf,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub language_reports: HashMap<String, LanguageReportSummary>,
    pub total_diagnostics: usize,
    pub total_fixes_applied: usize,
    pub total_remaining: usize,
    pub test_results: TestResults,
    pub success: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LanguageReportSummary {
    pub language: String,
    pub total_diagnostics: usize,
    pub auto_fixable: usize,
    pub review_required: usize,
    pub ai_candidates: usize,
    pub ignored: usize,
    pub fixes_applied: usize,
    pub fixes_failed: usize,
    pub files_formatted: usize,
    pub remaining_diagnostics: Vec<Diagnostic>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestResults {
    pub rust: Option<TestOutput>,
    pub dart: Option<TestOutput>,
    pub typescript: Option<TestOutput>,
    pub python: Option<TestOutput>,
    pub go: Option<TestOutput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestOutput {
    pub passed: bool,
    pub output: String,
    pub stderr: String,
}

impl FixReport {
    pub fn new() -> Self {
        Self {
            project_root: PathBuf::new(),
            timestamp: chrono::Utc::now(),
            language_reports: HashMap::new(),
            total_diagnostics: 0,
            total_fixes_applied: 0,
            total_remaining: 0,
            test_results: TestResults::new(),
            success: false,
        }
    }

    pub fn merge_language_report(&mut self, language: String, report: LanguageReport) {
        self.total_diagnostics += report.total_diagnostics;
        self.total_fixes_applied += report.fixes_applied;
        
        let summary = LanguageReportSummary {
            language: language.clone(),
            total_diagnostics: report.total_diagnostics,
            auto_fixable: report.auto_fixable,
            review_required: report.review_required,
            ai_candidates: report.ai_candidates,
            ignored: report.ignored,
            fixes_applied: report.fixes_applied,
            fixes_failed: report.fixes_failed,
            files_formatted: report.files_formatted,
            remaining_diagnostics: report.remaining_diagnostics,
        };
        
        self.language_reports.insert(language, summary);
    }

    pub fn total_fixes_applied(&self) -> usize {
        self.total_fixes_applied
    }

    pub fn total_remaining_diagnostics(&self) -> usize {
        self.language_reports.values().map(|r| r.remaining_diagnostics.len()).sum()
    }
}

impl TestResults {
    pub fn new() -> Self {
        Self {
            rust: None,
            dart: None,
            typescript: None,
            python: None,
            go: None,
        }
    }

    pub fn all_passed(&self) -> bool {
        [&self.rust, &self.dart, &self.typescript, &self.python, &self.go]
            .iter()
            .filter_map(|t| t.as_ref())
            .all(|t| t.passed)
    }
}

impl Default for FixReport {
    fn default() -> Self {
        Self::new()
    }
}