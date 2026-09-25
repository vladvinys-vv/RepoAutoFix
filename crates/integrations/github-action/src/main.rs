// GitHub Action for RepoAutoFix
// This runs as a standalone binary in the GitHub Actions environment

use octocrab::{models::repos::RepoCommit, Octocrab, Page};
use serde::{Deserialize, Serialize};
use std::env;
use std::path::PathBuf;
use std::process::Command;
use tokio::fs;

#[derive(Deserialize)]
struct ActionInputs {
    github_token: String,
    ai_enabled: bool,
    policy: String,
    fail_on_remaining: bool,
    create_pr: bool,
    pr_labels: String,
    pr_reviewers: String,
    config_file: Option<String>,
    working_directory: Option<String>,
}

#[derive(Serialize)]
struct ActionOutputs {
    has_fixes: bool,
    fixes_applied: usize,
    remaining_diagnostics: usize,
    pr_number: Option<u64>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let inputs = parse_inputs()?;
    
    let work_dir = inputs.working_directory
        .map(PathBuf::from)
        .unwrap_or_else(|| env::current_dir().unwrap());
    
    println!("🔧 RepoAutoFix GitHub Action");
    println!("Working directory: {}", work_dir.display());
    
    // Install repoautofix if needed
    install_repoautofix().await?;
    
    // Run repoautofix
    let report = run_repoautofix(&work_dir, &inputs).await?;
    
    // Set outputs
    set_output("has_fixes", report.has_fixes.to_string());
    set_output("fixes_applied", report.fixes_applied.to_string());
    set_output("remaining_diagnostics", report.remaining_diagnostics.to_string());
    
    // Create PR if fixes were applied
    if inputs.create_pr && report.has_fixes {
        let pr_number = create_pr(&inputs, &work_dir, &report).await?;
        set_output("pr_number", pr_number.to_string());
    }
    
    // Fail if configured
    if inputs.fail_on_remaining && report.remaining_diagnostics > 0 {
        eprintln!("❌ Found {} remaining diagnostics", report.remaining_diagnostics);
        std::process::exit(1);
    }
    
    println!("✅ RepoAutoFix completed successfully");
    Ok(())
}

fn parse_inputs() -> anyhow::Result<ActionInputs> {
    Ok(ActionInputs {
        github_token: get_input("github-token")?,
        ai_enabled: get_bool_input("ai-enabled")?,
        policy: get_input("policy").unwrap_or_else(|_| "balanced".to_string()),
        fail_on_remaining: get_bool_input("fail-on-remaining").unwrap_or(true),
        create_pr: get_bool_input("create-pr").unwrap_or(true),
        pr_labels: get_input("pr-labels").unwrap_or_else(|_| "autofix,bot".to_string()),
        pr_reviewers: get_input("pr-reviewers").unwrap_or_default(),
        config_file: get_input("config-file").ok(),
        working_directory: get_input("working-directory").ok(),
    })
}

fn get_input(name: &str) -> anyhow::Result<String> {
    env::var(format!("INPUT_{}", name.to_uppercase().replace('-', '_')))
        .map_err(|_| anyhow::anyhow!("Missing required input: {}", name))
}

fn get_bool_input(name: &str) -> anyhow::Result<bool> {
    let val = get_input(name)?;
    Ok(val.parse().unwrap_or(false))
}

fn set_output(name: &str, value: String) {
    if let Ok(github_output) = env::var("GITHUB_OUTPUT") {
        std::fs::OpenOptions::new()
            .append(true)
            .open(github_output)
            .map(|mut f| {
                use std::io::Write;
                writeln!(f, "{}={}", name, value).ok();
            });
    }
}

async fn install_repoautofix() -> anyhow::Result<()> {
    // Check if already installed
    if Command::new("repoautofix").arg("--version").output().is_ok() {
        println!("✅ repoautofix already installed");
        return Ok(());
    }
    
    println!("📦 Installing repoautofix...");
    
    // Try cargo install
    let output = Command::new("cargo")
        .args(["install", "repoautofix-cli", "--locked"])
        .output()?;
    
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        eprintln!("Failed to install via cargo: {}", stderr);
        
        // Try downloading binary
        download_binary().await?;
    }
    
    // Verify installation
    let output = Command::new("repoautofix").arg("--version").output()?;
    let version = String::from_utf8_lossy(&output.stdout);
    println!("✅ Installed repoautofix {}", version.trim());
    
    Ok(())
}

async fn download_binary() -> anyhow::Result<()> {
    // This would download a pre-built binary from GitHub releases
    // For now, we'll assume cargo install works
    println!("📥 Downloading pre-built binary...");
    // Implementation would go here
    Ok(())
}

async fn run_repoautofix(work_dir: &PathBuf, inputs: &ActionInputs) -> anyhow::Result<ActionOutputs> {
    let mut cmd = Command::new("repoautofix");
    cmd.current_dir(work_dir)
        .arg("fix")
        .arg("--policy")
        .arg(&inputs.policy);
    
    if inputs.ai_enabled {
        cmd.arg("--ai");
    }
    
    if inputs.fail_on_remaining {
        cmd.arg("--fail-on-remaining");
    }
    
    if let Some(config) = &inputs.config_file {
        cmd.arg("--config").arg(config);
    }
    
    println!("🚀 Running: repoautofix fix --policy {} {}", 
        inputs.policy, 
        if inputs.ai_enabled { "--ai" } else { "" }
    );
    
    let output = cmd.output()?;
    
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    
    println!("{}", stdout);
    if !stderr.is_empty() {
        eprintln!("{}", stderr);
    }
    
    // Parse output to extract metrics
    let (fixes_applied, remaining) = parse_report(&stdout);
    let has_fixes = fixes_applied > 0;
    
    Ok(ActionOutputs {
        has_fixes,
        fixes_applied,
        remaining_diagnostics: remaining,
        pr_number: None,
    })
}

fn parse_report(output: &str) -> (usize, usize) {
    let mut fixes_applied = 0;
    let mut remaining = 0;
    
    for line in output.lines() {
        if line.contains("Fixes applied:") || line.contains("Applied:") {
            if let Some(num) = extract_number(line) {
                fixes_applied = num;
            }
        }
        if line.contains("Remaining:") {
            if let Some(num) = extract_number(line) {
                remaining = num;
            }
        }
    }
    
    (fixes_applied, remaining)
}

fn extract_number(line: &str) -> Option<usize> {
    line.split_whitespace()
        .find_map(|s| s.parse().ok())
}

async fn create_pr(inputs: &ActionInputs, work_dir: &PathBuf, report: &ActionOutputs) -> anyhow::Result<u64> {
    println!("📝 Creating pull request...");
    
    // Check if there are changes
    let status_output = Command::new("git")
        .current_dir(work_dir)
        .args(["status", "--porcelain"])
        .output()?;
    
    let status = String::from_utf8_lossy(&status_output.stdout);
    if status.trim().is_empty() {
        println!("No changes to commit");
        return Ok(0);
    }
    
    // Configure git
    Command::new("git")
        .current_dir(work_dir)
        .args(["config", "user.name", "repoautofix[bot]"])
        .output()?;
    
    Command::new("git")
        .current_dir(work_dir)
        .args(["config", "user.email", "repoautofix@users.noreply.github.com"])
        .output()?;
    
    // Commit changes
    Command::new("git")
        .current_dir(work_dir)
        .args(["add", "-A"])
        .output()?;
    
    let commit_msg = format!("chore: automated code fixes by RepoAutoFix\n\nApplied {} fixes", report.fixes_applied);
    Command::new("git")
        .current_dir(work_dir)
        .args(["commit", "-m", &commit_msg])
        .output()?;
    
    // Push to a new branch
    let branch_name = format!("repoautofix/fixes-{}", chrono::Utc::now().format("%Y%m%d-%H%M%S"));
    Command::new("git")
        .current_dir(work_dir)
        .args(["push", "origin", &format!("HEAD:{}", branch_name)])
        .output()?;
    
    // Create PR via GitHub API
    let octocrab = Octocrab::builder()
        .personal_token(inputs.github_token.clone())
        .build()?;
    
    let repo = get_repo_info(&octocrab).await?;
    
    let pr = octocrab
        .pulls(&repo.0, &repo.1)
        .create("Automated code fixes by RepoAutoFix")
        .head(branch_name)
        .base("main")
        .body(format!(
            "## 🤖 Automated Code Fixes\n\nRepoAutoFix applied **{}** automated fixes.\n\n---\n*Generated by [RepoAutoFix](https://github.com/yourorg/repoautofix)*",
            report.fixes_applied
        ))
        .send()
        .await?;
    
    // Add labels
    let labels: Vec<&str> = inputs.pr_labels.split(',').map(|s| s.trim()).collect();
    if !labels.is_empty() {
        octocrab
            .issues(&repo.0, &repo.1)
            .add_labels(pr.number, &labels)
            .await?;
    }
    
    // Request reviewers
    if !inputs.pr_reviewers.is_empty() {
        let reviewers: Vec<&str> = inputs.pr_reviewers.split(',').map(|s| s.trim()).collect();
        octocrab
            .pulls(&repo.0, &repo.1)
            .request_reviewers(pr.number, &reviewers)
            .await?;
    }
    
    println!("✅ Created PR #{}", pr.number);
    Ok(pr.number)
}

async fn get_repo_info(octocrab: &Octocrab) -> anyhow::Result<(String, String)> {
    // Get repo from GITHUB_REPOSITORY env var
    let repo_full = env::var("GITHUB_REPOSITORY")?;
    let parts: Vec<&str> = repo_full.split('/').collect();
    if parts.len() != 2 {
        anyhow::bail!("Invalid GITHUB_REPOSITORY format");
    }
    Ok((parts[0].to_string(), parts[1].to_string()))
}