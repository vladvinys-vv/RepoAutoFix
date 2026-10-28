use clap::{Parser, Subcommand, ValueEnum};
use repoautofix_core::Project;
use repoautofix_engine::FixEngine;
use repoautofix_policy::{FixConfig, Policy};
use std::path::PathBuf;
use tracing::{info, warn, Level};
use tracing_subscriber::FmtSubscriber;

#[derive(Parser)]
#[command(name = "repoautofix")]
#[command(about = "Automated multi-language code fixing engine", long_about = None)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
    
    #[arg(short, long, global = true, help = "Project root directory")]
    root: Option<PathBuf>,
    
    #[arg(short, long, global = true, help = "Enable verbose logging")]
    verbose: bool,
    
    #[arg(long, global = true, help = "Dry run (default: true)")]
    dry_run: Option<bool>,
    
    #[arg(long, global = true, help = "Enable AI-assisted fixes")]
    ai: bool,
    
    #[arg(long, global = true, help = "Fail on remaining diagnostics")]
    fail_on_remaining: bool,
    
    #[arg(long, global = true, help = "Config file path")]
    config: Option<PathBuf>,
}

#[derive(Subcommand)]
enum Commands {
    /// Fix code issues in the repository
    Fix {
        #[arg(help = "Specific files to fix (default: all)")]
        files: Vec<PathBuf>,
        
        #[arg(long, help = "Policy profile: safe, balanced, aggressive")]
        policy: Option<PolicyProfile>,
        
        #[arg(long, help = "Only fix staged files")]
        staged: bool,
    },
    
    /// Check for issues without fixing
    Check {
        #[arg(help = "Specific files to check")]
        files: Vec<PathBuf>,
        
        #[arg(long, help = "Output format: text, json, sarif")]
        format: Option<OutputFormat>,
    },
    
    /// Format code
    Format {
        #[arg(help = "Specific files to format")]
        files: Vec<PathBuf>,
    },
    
    /// Initialize RepoAutoFix in a project
    Init {
        #[arg(long, help = "Force overwrite existing config")]
        force: bool,
    },
    
    /// Show configuration
    Config {
        #[arg(long, help = "Show effective config as JSON")]
        json: bool,
    },
    
    /// List available language adapters
    Languages,
}

#[derive(ValueEnum, Clone, Debug)]
enum PolicyProfile {
    Safe,
    Balanced,
    Aggressive,
}

#[derive(ValueEnum, Clone, Debug)]
enum OutputFormat {
    Text,
    Json,
    Sarif,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    
    // Setup logging
    let level = if cli.verbose { Level::DEBUG } else { Level::INFO };
    let subscriber = FmtSubscriber::builder()
        .with_max_level(level)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;
    
    let root = cli.root.unwrap_or_else(|| std::env::current_dir().unwrap());
    info!("RepoAutoFix running in: {}", root.display());
    
    // Load config
    let mut config = load_config(cli.config.as_deref(), &root).await?;
    
    // Override from CLI
    if let Some(dry_run) = cli.dry_run {
        config.dry_run = dry_run;
    }
    if cli.ai {
        config.enable_ai = true;
    }
    if cli.fail_on_remaining {
        config.fail_on_remaining = true;
    }
    if let Some(profile) = cli.command.get_policy_profile() {
        config.policy = profile.into();
    }
    
    // Run command
    match cli.command {
        Commands::Fix { files, policy: _, staged } => {
            run_fix(&root, &config, files, staged).await?;
        }
        Commands::Check { files, format } => {
            run_check(&root, &config, files, format).await?;
        }
        Commands::Format { files } => {
            run_format(&root, files).await?;
        }
        Commands::Init { force } => {
            run_init(&root, force).await?;
        }
        Commands::Config { json } => {
            run_config(&config, json).await?;
        }
        Commands::Languages => {
            run_languages().await?;
        }
    }
    
    Ok(())
}

async fn load_config(config_path: Option<&Path>, root: &Path) -> anyhow::Result<FixConfig> {
    if let Some(path) = config_path {
        if path.exists() {
            let content = std::fs::read_to_string(path)?;
            let config: FixConfig = serde_yaml::from_str(&content)?;
            return Ok(config);
        }
    }
    
    // Look for default config files
    for name in &[".repoautofix.yml", ".repoautofix.yaml", "repoautofix.yml", "repoautofix.yaml"] {
        let path = root.join(name);
        if path.exists() {
            let content = std::fs::read_to_string(&path)?;
            let config: FixConfig = serde_yaml::from_str(&content)?;
            return Ok(config);
        }
    }
    
    Ok(FixConfig::default())
}

async fn run_fix(root: &Path, config: &FixConfig, files: Vec<PathBuf>, staged: bool) -> anyhow::Result<()> {
    let mut project = Project::new(root.to_path_buf());
    project.detect_languages();
    
    let engine = FixEngine::new(config.clone());
    let report = engine.run_fix_cycle(&project).await?;
    
    // Print report
    print_report(&report);
    
    if config.fail_on_remaining && report.total_remaining_diagnostics() > 0 {
        std::process::exit(1);
    }
    
    Ok(())
}

async fn run_check(root: &Path, config: &FixConfig, files: Vec<PathBuf>, format: Option<OutputFormat>) -> anyhow::Result<()> {
    let mut project = Project::new(root.to_path_buf());
    project.detect_languages();
    
    let engine = FixEngine::new(config.clone());
    
    // Just lint, don't fix
    let mut check_config = config.clone();
    check_config.dry_run = true;
    
    let report = engine.run_fix_cycle(&project).await?;
    
    match format.unwrap_or(OutputFormat::Text) {
        OutputFormat::Text => print_report(&report),
        OutputFormat::Json => println!("{}", serde_json::to_string_pretty(&report)?),
        OutputFormat::Sarif => println!("{}", to_sarif(&report)?),
    }
    
    if check_config.fail_on_remaining && report.total_remaining_diagnostics() > 0 {
        std::process::exit(1);
    }
    
    Ok(())
}

async fn run_format(root: &Path, files: Vec<PathBuf>) -> anyhow::Result<()> {
    let mut project = Project::new(root.to_path_buf());
    project.detect_languages();
    
    let engine = FixEngine::new(FixConfig::default());
    
    for adapter in engine.registry().all() {
        if !adapter.is_available().await {
            continue;
        }
        
        let result = if files.is_empty() {
            adapter.format(&project).await?
        } else {
            let mut combined = repoautofix_core::FormatResult {
                files_changed: 0,
                files_formatted: Vec::new(),
                errors: Vec::new(),
            };
            for file in &files {
                let r = adapter.format_file(file).await?;
                combined.files_changed += r.files_changed;
                combined.files_formatted.extend(r.files_formatted);
                combined.errors.extend(r.errors);
            }
            combined
        };
        
        info!("{} formatted {} files", adapter.name(), result.files_changed);
        for file in &result.files_formatted {
            println!("  {}", file.display());
        }
        for err in &result.errors {
            warn!("Format error in {}: {}", err.file.display(), err.error);
        }
    }
    
    Ok(())
}

async fn run_init(root: &Path, force: bool) -> anyhow::Result<()> {
    let config_path = root.join(".repoautofix.yml");
    
    if config_path.exists() && !force {
        anyhow::bail!("Config already exists at {}. Use --force to overwrite.", config_path.display());
    }
    
    let default_config = r#"# RepoAutoFix Configuration
version: 1

# Languages to process (auto-detected if not specified)
# languages:
#   - rust
#   - dart
#   - typescript
#   - python
#   - go

policy:
  # Global settings
  max_files_per_run: 50
  max_edits_per_file: 20
  require_tests_pass: true
  require_clean_git: true
  dry_run_default: true
  
  # Per-language overrides (optional)
  # overrides:
  #   rust:
  #     max_edits_per_file: 10

# Rule customization
rules:
  - pattern: "unused_import"
    action: "auto_apply"
  - pattern: "clippy::unwrap_used"
    action: "ai_assist"
    languages: ["rust"]
  - pattern: "security/"
    action: "require_review"

# AI Configuration
ai:
  provider: "anthropic"
  model: "claude-3-5-sonnet-20241022"
  max_rounds: 10
  temperature: 0.1

# CI/CD
ci:
  fail_on_remaining: true
  create_pr: true
  pr_labels: ["autofix", "bot"]

# Pre-commit
pre_commit:
  enabled: true
  staged_only: true
  timeout_seconds: 30
"#;
    
    std::fs::write(&config_path, default_config)?;
    info!("Created config at {}", config_path.display());
    
    Ok(())
}

async fn run_config(config: &FixConfig, json: bool) -> anyhow::Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(config)?);
    } else {
        println!("{}", serde_yaml::to_string(config)?);
    }
    Ok(())
}

async fn run_languages() -> anyhow::Result<()> {
    let engine = FixEngine::new(FixConfig::default());
    
    println!("Available language adapters:");
    for adapter in engine.registry().all() {
        let available = if adapter.is_available().await { "✓" } else { "✗" };
        println!("  {} {} ({:?})", available, adapter.name(), adapter.file_extensions());
    }
    
    Ok(())
}

fn print_report(report: &repoautofix_policy::FixReport) {
    println!("\n=== RepoAutoFix Report ===");
    println!("Project: {}", report.project_root.display());
    println!("Time: {}", report.timestamp.format("%Y-%m-%d %H:%M:%S UTC"));
    println!();
    
    println!("Summary:");
    println!("  Total diagnostics: {}", report.total_diagnostics);
    println!("  Fixes applied:     {}", report.total_fixes_applied);
    println!("  Remaining:         {}", report.total_remaining_diagnostics());
    println!();
    
    for (lang, summary) in &report.language_reports {
        println!("Language: {}", lang);
        println!("  Diagnostics:     {}", summary.total_diagnostics);
        println!("  Auto-fixable:    {}", summary.auto_fixable);
        println!("  Review required: {}", summary.review_required);
        println!("  AI candidates:   {}", summary.ai_candidates);
        println!("  Ignored:         {}", summary.ignored);
        println!("  Applied:         {}", summary.fixes_applied);
        println!("  Failed:          {}", summary.fixes_failed);
        println!("  Formatted:       {}", summary.files_formatted);
        println!("  Remaining:       {}", summary.remaining_diagnostics.len());
        
        if !summary.remaining_diagnostics.is_empty() {
            println!("  Remaining issues:");
            for diag in &summary.remaining_diagnostics {
                println!("    [{:?}] {}:{} {} - {}", 
                    diag.severity,
                    diag.file.file_name().unwrap_or_default().to_string_lossy(),
                    diag.range.start.line + 1,
                    diag.code,
                    diag.message);
            }
        }
        println!();
    }
    
    if report.test_results.rust.is_some() || report.test_results.dart.is_some() {
        println!("Test Results:");
        if let Some(t) = &report.test_results.rust {
            println!("  Rust:    {}", if t.passed { "✓ PASSED" } else { "✗ FAILED" });
        }
        if let Some(t) = &report.test_results.dart {
            println!("  Dart:    {}", if t.passed { "✓ PASSED" } else { "✗ FAILED" });
        }
        println!();
    }
}

fn to_sarif(report: &repoautofix_policy::FixReport) -> anyhow::Result<String> {
    // Simplified SARIF output
    let sarif = json!({
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [{
            "tool": {
                "driver": {
                    "name": "RepoAutoFix",
                    "version": env!("CARGO_PKG_VERSION"),
                    "informationUri": "https://github.com/yourorg/repoautofix"
                }
            },
            "results": report.language_reports.values().flat_map(|r| &r.remaining_diagnostics).map(|d| {
                json!({
                    "ruleId": d.code,
                    "message": { "text": d.message },
                    "locations": [{
                        "physicalLocation": {
                            "artifactLocation": { "uri": d.file.to_string_lossy() },
                            "region": {
                                "startLine": d.range.start.line + 1,
                                "startColumn": d.range.start.column + 1,
                                "endLine": d.range.end.line + 1,
                                "endColumn": d.range.end.column + 1
                            }
                        }
                    }],
                    "level": match d.severity {
                        repoautofix_core::Severity::Error => "error",
                        repoautofix_core::Severity::Warning => "warning",
                        repoautofix_core::Severity::Info => "note",
                        repoautofix_core::Severity::Hint => "note",
                    }
                })
            }).collect::<Vec<_>>()
        }]
    });
    
    Ok(serde_json::to_string_pretty(&sarif)?)
}

impl Commands {
    fn get_policy_profile(&self) -> Option<PolicyProfile> {
        match self {
            Commands::Fix { policy, .. } => policy.clone(),
            _ => None,
        }
    }
}

impl From<PolicyProfile> for Policy {
    fn from(profile: PolicyProfile) -> Self {
        match profile {
            PolicyProfile::Safe => Policy {
                rules: vec![
                    repoautofix_policy::PolicyRule {
                        pattern: "unused_import".to_string(),
                        languages: vec![],
                        action: repoautofix_policy::FixAction::AutoApply,
                        min_severity: repoautofix_core::Severity::Hint,
                        max_severity: repoautofix_core::Severity::Warning,
                    },
                ],
                global: repoautofix_policy::GlobalPolicy {
                    max_files_per_run: 20,
                    max_edits_per_file: 5,
                    require_tests_pass: true,
                    require_clean_git: true,
                    allowed_ai_providers: vec![],
                    dry_run_default: true,
                },
            },
            PolicyProfile::Balanced => Policy::default(),
            PolicyProfile::Aggressive => Policy {
                rules: vec![
                    repoautofix_policy::PolicyRule {
                        pattern: ".*".to_string(),
                        languages: vec![],
                        action: repoautofix_policy::FixAction::AutoApply,
                        min_severity: repoautofix_core::Severity::Hint,
                        max_severity: repoautofix_core::Severity::Error,
                    },
                ],
                global: repoautofix_policy::GlobalPolicy {
                    max_files_per_run: 100,
                    max_edits_per_file: 50,
                    require_tests_pass: false,
                    require_clean_git: false,
                    allowed_ai_providers: vec!["anthropic".to_string(), "openai".to_string()],
                    dry_run_default: false,
                },
            },
        }
    }
}