# RepoAutoFix

**Automated, multi-language code fixing engine** that integrates linting, formatting, and AI-assisted repairs into your development workflow.

[![Crates.io](https://img.shields.io/crates/v/repoautofix-cli)](https://crates.io/crates/repoautofix-cli)
[![GitHub Actions](https://github.com/yourorg/repoautofix/workflows/CI/badge.svg)](https://github.com/yourorg/repoautofix/actions)
[![License](https://img.shields.io/badge/license-MIT%2FApache-blue.svg)](LICENSE)

## Features

| Feature | Description |
|---------|-------------|
| **Multi-language** | Rust, Dart, TypeScript/JavaScript, Python, Go |
| **Lint→Fix loops** | Runs linters, applies fixes, re-lints to verify |
| **AI-assisted fixes** | Uses LLMs for complex issues (logic bugs, unwrap, performance) |
| **Policy-driven** | Configure which fixes are auto-applied vs. reviewed |
| **Safety first** | Backups, test gates, git cleanliness checks, dry-run default |
| **CI/CD integration** | GitHub Actions, GitLab CI, pre-commit hooks |
| **Library API** | Embed in your own tools |

## Quick Start

```bash
# Install
cargo install repoautofix-cli

# Initialize in your project
cd your-project
repoautofix init

# Check for issues (dry run)
repoautofix check

# Fix issues
repoautofix fix

# Fix with AI for complex issues
repoautofix fix --ai
```

## Supported Languages & Tools

| Language | Linter | Auto-fix | Formatter |
|----------|--------|----------|-----------|
| **Rust** | `cargo clippy` | `cargo fix` | `rustfmt` |
| **Dart** | `dart analyze` | `dart fix` | `dart format` |
| **TypeScript** | `eslint` | `eslint --fix` | `prettier` |
| **Python** | `ruff` / `pylint` | `ruff --fix` | `ruff format` / `black` |
| **Go** | `go vet` / `golangci-lint` | `go fix` | `gofmt` |

## Configuration

Create `.repoautofix.yml` in your project root:

```yaml
version: 1

policy:
  max_files_per_run: 50
  max_edits_per_file: 20
  require_tests_pass: true
  require_clean_git: true
  dry_run_default: true

rules:
  - pattern: "unused_import"
    action: "auto_apply"
  - pattern: "clippy::unwrap_used"
    action: "ai_assist"
    languages: ["rust"]
  - pattern: "security/"
    action: "require_review"

ai:
  provider: "anthropic"
  model: "claude-3-5-sonnet-20241022"
  max_rounds: 10
  temperature: 0.1
```

## CLI Usage

```bash
# Fix entire repo (dry run by default)
repoautofix fix

# Fix specific files
repoautofix fix src/main.rs src/lib.rs

# Apply fixes (not dry run)
repoautofix fix --no-dry-run

# Use AI for complex fixes
repoautofix fix --ai

# Policy profiles
repoautofix fix --policy=safe      # Conservative
repoautofix fix --policy=balanced  # Default
repoautofix fix --policy=aggressive # More aggressive

# CI mode (exits with error code if issues remain)
repoautofix fix --ci --fail-on-remaining

# Check only (no fixes)
repoautofix check

# Format code
repoautofix format

# Initialize config
repoautofix init
```

## GitHub Actions

Add `.github/workflows/repoautofix.yml`:

```yaml
name: RepoAutoFix
on: [pull_request, push]

jobs:
  autofix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: repoautofix/action@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          ai-enabled: true
          policy: balanced
      - name: Create PR with fixes
        if: steps.autofix.outputs.has-fixes == 'true'
        uses: peter-evans/create-pull-request@v5
        with:
          labels: autofix, bot
          reviewers: team-leads
```

## Pre-commit Hook

Install locally:

```bash
# Install hook
repoautofix-pre-commit install

# Or add to .pre-commit-config.yaml
repos:
  - repo: local
    hooks:
      - id: repoautofix
        name: RepoAutoFix
        entry: repoautofix fix --staged --dry-run
        language: system
        types: [rust, python, dart, typescript, go]
        pass_filenames: true
```

Then run `pre-commit install`.

## Library Usage

```rust
use repoautofix::{FixEngine, FixConfig, Policy};

let engine = FixEngine::new(FixConfig {
    enable_ai: true,
    format: true,
    run_tests: true,
    dry_run: false,
    ..Default::default()
}).with_adapter(DartAdapter::new())
 .with_adapter(RustAdapter::new());

let report = engine.run_fix_cycle(&project).await?;
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      RepoAutoFix Core                        │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │ Language     │  │ Fix Engine   │  │ Policy Manager     │  │
│  │ Adapters     │──▶│ (Lint→Fix)   │──▶│ (Severity/Action)  │  │
│  └──────────────┘  └──────────────┘  └────────────────────┘  │
│         ▲                ▲                     ▲              │
│         │                │                     │              │
│  ┌──────┴──────┐  ┌─────┴─────┐        ┌──────┴──────┐       │
│  │ Dart        │  │ AI Fix    │        │ Safety      │       │
│  │ Rust        │  │ Agent     │        │ Guards      │       │
│  │ TypeScript  │  │ (LLM)     │        │             │       │
│  │ Python      │  │           │        │ - Max edits │       │
│  │ Go          │  │           │        │ - Tests run │       │
│  └─────────────┘  └───────────┘        └─────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

## How It Differs from GitSync Auto-Fix

| Aspect | GitSync Auto-Fix | RepoAutoFix |
|--------|------------------|-------------|
| **Scope** | Git repo corruption only | Code-level issues (lint, style, security, perf) |
| **Trigger** | Automatic on corruption | Scheduled, CI, pre-commit, manual |
| **Fix Type** | Delete corrupted files | Precise code edits via linters + AI |
| **Languages** | Git-level only | 5+ languages with native toolchains |
| **AI Role** | Git assistant (commit, push, branch) | Code fix specialist (logic, types, patterns) |
| **Safety** | Retry loop (can infinite loop) | Policy-driven, test-gated, backup-protected |

## Development

```bash
# Build
cargo build --workspace --release

# Test
cargo test --workspace

# Run locally
cargo run --bin repoautofix -- fix
```

## License

Licensed under either of:
- Apache License, Version 2.0 (LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license (LICENSE-MIT or http://opensource.org/licenses/MIT)

## Contributing

Contributions welcome! Please read CONTRIBUTING.md first.