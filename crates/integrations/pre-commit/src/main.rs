// Pre-commit hook for RepoAutoFix
// This can be installed via: repoautofix-pre-commit install

use clap::{Parser, Subcommand};
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[derive(Parser)]
#[command(name = "repoautofix-pre-commit")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Install the pre-commit hook
    Install {
        #[arg(long, help = "Force overwrite existing hook")]
        force: bool,
    },
    
    /// Uninstall the pre-commit hook
    Uninstall,
    
    /// Run the hook (called by git)
    Run {
        #[arg(help = "Files to check (passed by git)")]
        files: Vec<String>,
    },
    
    /// Generate .pre-commit-config.yaml
    GenerateConfig,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    
    match cli.command {
        Commands::Install { force } => install_hook(force),
        Commands::Uninstall => uninstall_hook(),
        Commands::Run { files } => run_hook(files),
        Commands::GenerateConfig => generate_config(),
    }
}

fn install_hook(force: bool) -> anyhow::Result<()> {
    let git_dir = find_git_dir()?;
    let hooks_dir = git_dir.join("hooks");
    let hook_path = hooks_dir.join("pre-commit");
    
    if hook_path.exists() && !force {
        anyhow::bail!("Pre-commit hook already exists. Use --force to overwrite.");
    }
    
    fs::create_dir_all(&hooks_dir)?;
    
    let hook_content = r#"#!/bin/sh
# RepoAutoFix pre-commit hook
# This hook runs repoautofix on staged files

# Find repoautofix binary
REPOAUTOFIX="repoautofix"
if ! command -v "$REPOAUTOFIX" >/dev/null 2>&1; then
    # Try cargo install path
    if [ -f "$HOME/.cargo/bin/repoautofix" ]; then
        REPOAUTOFIX="$HOME/.cargo/bin/repoautofix"
    else
        echo "repoautofix not found. Install with: cargo install repoautofix-cli"
        exit 1
    fi
done

# Get staged files
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM)

if [ -z "$STAGED_FILES" ]; then
    exit 0
fi

# Run repoautofix on staged files only (dry-run by default)
echo "Running RepoAutoFix on staged files..."
exec "$REPOAUTOFIX" fix --staged --dry-run $STAGED_FILES
"#;
    
    fs::write(&hook_path, hook_content)?;
    
    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&hook_path)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&hook_path, perms)?;
    }
    
    println!("✅ Installed pre-commit hook at {}", hook_path.display());
    Ok(())
}

fn uninstall_hook() -> anyhow::Result<()> {
    let git_dir = find_git_dir()?;
    let hook_path = git_dir.join("hooks").join("pre-commit");
    
    if hook_path.exists() {
        fs::remove_file(&hook_path)?;
        println!("✅ Removed pre-commit hook");
    } else {
        println!("No pre-commit hook found");
    }
    
    Ok(())
}

fn run_hook(files: Vec<String>) -> anyhow::Result<()> {
    if files.is_empty() {
        return Ok(());
    }
    
    // Filter files by supported extensions
    let supported_exts = ["rs", "dart", "ts", "tsx", "js", "jsx", "py", "go"];
    let filtered: Vec<_> = files.iter()
        .filter(|f| {
            PathBuf::from(f).extension()
                .and_then(|e| e.to_str())
                .map(|e| supported_exts.contains(&e))
                .unwrap_or(false)
        })
        .collect();
    
    if filtered.is_empty() {
        return Ok(());
    }
    
    println!("🔍 RepoAutoFix checking {} staged files...", filtered.len());
    
    let mut cmd = Command::new("repoautofix");
    cmd.arg("fix")
        .arg("--staged")
        .arg("--dry-run")
        .args(filtered);
    
    let status = cmd.status()?;
    
    if !status.success() {
        eprintln!("❌ RepoAutoFix found issues. Run 'repoautofix fix' to fix them.");
        std::process::exit(1);
    }
    
    println!("✅ RepoAutoFix: no issues found");
    Ok(())
}

fn generate_config() -> anyhow::Result<()> {
    let config = r#"# .pre-commit-config.yaml
# Add this to your .pre-commit-config.yaml to use RepoAutoFix

repos:
  - repo: local
    hooks:
      - id: repoautofix
        name: RepoAutoFix
        entry: repoautofix fix --staged --dry-run
        language: system
        types: [rust, python, dart, typescript, go]
        pass_filenames: true
        always_run: false
        # Optional: only run on staged files (faster)
        # stages: [commit]
        # Optional: timeout in seconds
        # timeout: 30
"#;
    
    println!("{}", config);
    Ok(())
}

fn find_git_dir() -> anyhow::Result<PathBuf> {
    let output = Command::new("git")
        .args(["rev-parse", "--git-dir"])
        .output()?;
    
    if !output.status.success() {
        anyhow::bail!("Not a git repository");
    }
    
    let git_dir = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok(PathBuf::from(git_dir))
}