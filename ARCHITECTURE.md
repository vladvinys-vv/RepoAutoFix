# RepoAutoFix Architecture

## Vision
Automated, multi-language code fixing engine that integrates with GitSync's AI agent framework, providing:
- **Lint→Fix loops** for Dart, Rust, TypeScript, Python, Go
- **AI-powered fixes** for complex issues (logic bugs, security, performance)
- **CI/CD & pre-commit integration** with safety guards
- **Policy-driven** auto-apply vs. review-required rules

---

## Core Architecture

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
         │                │                     │
         ▼                ▼                     ▼
┌─────────────────────────────────────────────────────────────┐
│                    Integration Layer                         │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐  │
│  │ CLI      │ │ Library  │ │ GitHub   │ │ Pre-commit     │  │
│  │ (repoautofix)│ │ API      │ │ Action   │ │ Hook           │  │
│  └──────────┘ └──────────┘ └──────────┘ └────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## Language Adapters

Each adapter implements `LanguageAdapter` trait:

```rust
pub trait LanguageAdapter: Send + Sync {
    fn name(&self) -> &'static str;
    fn file_extensions(&self) -> &[&'static str];
    
    // Linting
    fn lint(&self, project: &Project) -> Result<Vec<Diagnostic>>;
    fn lint_file(&self, file: &Path) -> Result<Vec<Diagnostic>>;
    
    // Auto-fix (built-in)
    fn auto_fix(&self, project: &Project, diagnostics: &[Diagnostic]) -> Result<FixResult>;
    fn auto_fix_file(&self, file: &Path, diagnostics: &[Diagnostic]) -> Result<FixResult>;
    
    // Formatting
    fn format(&self, project: &Project) -> Result<FormatResult>;
    fn format_file(&self, file: &Path) -> Result<FormatResult>;
    
    // AI-assisted fixes (complex issues)
    fn ai_fix_context(&self, diagnostic: &Diagnostic, file: &Path) -> AiFixContext;
}
```

### Supported Languages & Tools

| Language | Linter | Auto-fix | Formatter | AI Context |
|----------|--------|----------|-----------|------------|
| **Dart** | `dart analyze` | `dart fix --apply` | `dart format` | Pubspec, imports, types |
| **Rust** | `cargo clippy` | `cargo fix` | `rustfmt` | Cargo.toml, types, traits |
| **TypeScript** | `eslint` | `eslint --fix` | `prettier` | tsconfig, imports, types |
| **Python** | `ruff` / `pylint` | `ruff --fix` | `ruff format` / `black` | pyproject.toml, imports |
| **Go** | `go vet` / `golangci-lint` | `go fix` | `gofmt` | go.mod, imports |

---

## Fix Engine

### Lint→Fix Loop

```rust
pub struct FixEngine {
    adapters: HashMap<String, Box<dyn LanguageAdapter>>,
    policy: PolicyManager,
    ai_agent: Option<AiFixAgent>,
}

impl FixEngine {
    pub async fn run_fix_cycle(&self, project: &Project, config: &FixConfig) -> Result<FixReport> {
        let mut report = FixReport::new();
        
        // 1. Discover files by language
        let files_by_lang = self.discover_files(project)?;
        
        for (lang, files) in files_by_lang {
            let adapter = self.adapters.get(&lang).unwrap();
            
            // 2. Lint
            let diagnostics = adapter.lint(project)?;
            report.add_diagnostics(lang.clone(), diagnostics.clone());
            
            // 3. Categorize by policy
            let (auto_fixable, review_required, ai_candidates) = 
                self.policy.categorize(&diagnostics);
            
            // 4. Apply auto-fixes
            if !auto_fixable.is_empty() {
                let result = adapter.auto_fix(project, &auto_fixable)?;
                report.add_fixes(lang.clone(), result);
                
                // 5. Re-lint to verify
                let remaining = adapter.lint(project)?;
                report.add_remaining(lang.clone(), remaining);
            }
            
            // 6. AI-assisted fixes for complex issues
            if config.enable_ai && !ai_candidates.is_empty() {
                let ai_results = self.ai_agent.fix_batch(ai_candidates).await?;
                report.add_ai_fixes(lang.clone(), ai_results);
            }
            
            // 7. Format
            if config.format {
                let fmt_result = adapter.format(project)?;
                report.add_formatting(lang.clone(), fmt_result);
            }
        }
        
        // 8. Run tests if configured
        if config.run_tests {
            report.test_results = self.run_tests(project).await?;
        }
        
        Ok(report)
    }
}
```

---

## Policy Manager

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Policy {
    pub rules: Vec<PolicyRule>,
    pub global: GlobalPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyRule {
    pub pattern: String,           // Regex on diagnostic code/message
    pub languages: Vec<String>,    // Empty = all
    pub action: FixAction,
    pub min_severity: Severity,
    pub max_severity: Severity,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum FixAction {
    AutoApply,          // Apply without confirmation
    RequireReview,      // Create PR/comment for review
    AiAssist,           // Send to AI agent
    Ignore,             // Skip
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalPolicy {
    pub max_files_per_run: usize,
    pub max_edits_per_file: usize,
    pub require_tests_pass: bool,
    pub require_clean_git: bool,
    pub allowed_ai_providers: Vec<String>,
}
```

### Default Policies (Safe by Default)

| Pattern | Action | Rationale |
|---------|--------|-----------|
| `unused_import` | `AutoApply` | Safe, no behavior change |
| `dead_code` | `RequireReview` | May be intentionally kept |
| `clippy::unwrap_used` | `AiAssist` | Needs context for proper fix |
| `security/audit` | `RequireReview` | High impact |
| `performance/*` | `AiAssist` | Complex tradeoffs |
| `style/*` | `AutoApply` | Formatting only |

---

## AI Fix Agent

Uses GitSync's tool framework pattern:

```rust
pub struct AiFixAgent {
    client: LlmClient,
    tools: Vec<Box<dyn AiTool>>,
    system_prompt: String,
}

impl AiFixAgent {
    pub async fn fix_batch(&self, candidates: Vec<AiFixCandidate>) -> Result<Vec<AiFixResult>> {
        let mut results = Vec::new();
        
        for candidate in candidates {
            // Build context: file content, diagnostic, related code, tests
            let context = self.build_context(&candidate)?;
            
            // Run agentic loop (max 10 rounds)
            let result = self.run_agentic_fix(context).await?;
            results.push(result);
        }
        
        results
    }
    
    async fn run_agentic_fix(&self, context: AiFixContext) -> Result<AiFixResult> {
        let mut messages = vec![
            Message::system(&self.system_prompt),
            Message::user(&context.to_prompt()),
        ];
        
        for round in 0..10 {
            let response = self.client.chat(messages.clone(), &self.tools).await?;
            
            if response.tool_calls.is_empty() {
                // AI provided final fix
                return self.parse_fix_response(&response.content);
            }
            
            // Execute tools (read_file, edit_file, run_test, search_code, etc.)
            for tool_call in response.tool_calls {
                let tool = self.tools.iter().find(|t| t.name() == tool_call.name).unwrap();
                let result = tool.execute(tool_call.args).await?;
                messages.push(Message::tool_result(tool_call.id, result));
            }
            
            messages.push(Message::assistant(response.content));
        }
        
        Err(anyhow!("Max rounds exceeded"))
    }
}
```

### AI Tools (extending GitSync's pattern)

| Tool | Purpose | Confirmation |
|------|---------|--------------|
| `read_file` | Read source file | None |
| `edit_file` | Apply precise edit | Warn |
| `run_lint` | Re-run linter on file | None |
| `run_tests` | Run related tests | None |
| `search_code` | Find similar patterns | None |
| `get_type_info` | Query LSP for types | None |
| `view_diff` | Show proposed changes | None |

---

## Safety Guards

```rust
pub struct SafetyGuards {
    pub max_edits_per_file: usize,
    pub max_files_per_run: usize,
    pub require_tests_pass: bool,
    pub require_clean_git_status: bool,
    pub backup_before_edit: bool,
    pub dry_run_default: bool,
}

impl SafetyGuards {
    pub fn validate(&self, plan: &FixPlan) -> Result<()> {
        if plan.total_edits > self.max_edits_per_file * plan.files.len() {
            bail!("Exceeds max edits limit");
        }
        if plan.files.len() > self.max_files_per_run {
            bail!("Exceeds max files limit");
        }
        if self.require_clean_git_status && !git_status_clean()? {
            bail!("Working directory not clean");
        }
        Ok(())
    }
    
    pub fn create_backup(&self, file: &Path) -> Result<PathBuf> {
        let backup = file.with_extension(format!("{}.bak", file.extension().unwrap_or_default()));
        fs::copy(file, &backup)?;
        Ok(backup)
    }
}
```

---

## Integration Points

### 1. CLI (`repoautofix`)

```bash
# Fix entire repo
repoautofix fix

# Fix specific files
repoautofix fix src/main.rs src/lib.rs

# Dry run (default)
repoautofix fix --dry-run

# Apply with AI for complex issues
repoautofix fix --ai

# CI mode (exit code on remaining issues)
repoautofix fix --ci --fail-on-remaining

# Policy override
repoautofix fix --policy=aggressive
```

### 2. Library API

```rust
use repoautofix::{FixEngine, FixConfig, Policy};

let engine = FixEngine::new()
    .with_adapter(DartAdapter::new())
    .with_adapter(RustAdapter::new())
    .with_policy(Policy::default())
    .with_ai_agent(AiFixAgent::new(anthropic_key));

let report = engine.run_fix_cycle(&project, &FixConfig {
    enable_ai: true,
    format: true,
    run_tests: true,
    dry_run: false,
}).await?;
```

### 3. GitHub Action

```yaml
# .github/workflows/repoautofix.yml
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
```

### 4. Pre-commit Hook

```yaml
# .pre-commit-config.yaml
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

---

## Configuration

```yaml
# .repoautofix.yml
version: 1
languages:
  - dart
  - rust
  - typescript
  - python
  - go

policy:
  # Global settings
  max_files_per_run: 50
  max_edits_per_file: 20
  require_tests_pass: true
  require_clean_git: true
  dry_run_default: true
  
  # Per-language overrides
  overrides:
    rust:
      max_edits_per_file: 10  # More conservative for Rust
    dart:
      enable_ai: true

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
  allowed_tools: ["read_file", "edit_file", "run_lint", "run_tests", "search_code"]

# CI/CD
ci:
  fail_on_remaining: true
  create_pr: true
  pr_labels: ["autofix", "bot"]
  pr_reviewers: ["team-leads"]

# Pre-commit
pre_commit:
  enabled: true
  staged_only: true
  timeout_seconds: 30
```

---

## Implementation Phases

### Phase 1: Core Engine (Week 1-2)
- [ ] LanguageAdapter trait + registry
- [ ] Dart, Rust, TypeScript adapters (lint + auto-fix + format)
- [ ] FixEngine with lint→fix loop
- [ ] Basic CLI

### Phase 2: Policy & Safety (Week 2-3)
- [ ] PolicyManager with YAML config
- [ ] SafetyGuards (backups, limits, git checks)
- [ ] FixReport with detailed output

### Phase 3: AI Agent (Week 3-4)
- [ ] AiFixAgent with tool framework
- [ ] Core tools: read_file, edit_file, run_lint, run_tests
- [ ] LSP integration for type info
- [ ] Prompt engineering for fix quality

### Phase 4: Integrations (Week 4-5)
- [ ] GitHub Action
- [ ] Pre-commit hook
- [ ] GitLab CI template
- [ ] Library API stabilization

### Phase 5: Polish (Week 5-6)
- [ ] Python & Go adapters
- [ ] Performance optimization (parallel linting)
- [ ] Comprehensive tests
- [ ] Documentation & examples

---

## Key Differences from GitSync Auto-Fix

| Aspect | GitSync Auto-Fix | RepoAutoFix |
|--------|------------------|-------------|
| **Scope** | Git repo corruption only | Code-level issues (lint, style, security, perf) |
| **Trigger** | Automatic on corruption | Scheduled, CI, pre-commit, manual |
| **Fix Type** | Delete corrupted files | Precise code edits via linters + AI |
| **Languages** | Git-level only | 5+ languages with native toolchains |
| **AI Role** | Git assistant (commit, push, branch) | Code fix specialist (logic, types, patterns) |
| **Safety** | Retry loop (can infinite loop) | Policy-driven, test-gated, backup-protected |
| **Integration** | Mobile app only | CLI, Library, CI/CD, Pre-commit, IDE |

---

## Success Metrics

- **Auto-fix rate**: % of diagnostics resolved without human intervention
- **False positive rate**: % of applied fixes that break tests
- **Time saved**: Developer hours saved per PR
- **Adoption**: % of repos in org using RepoAutoFix
- **Language coverage**: % of codebase covered by adapters