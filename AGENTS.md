# Project rules: RepoAutoFix (RepoSync AI)

Global rules live in ~/.zcode/AGENTS.md. This file adds project specifics.
HANDOFF.md is the full contract (mission, queue, acceptance per task).

## Project
- What it is: RepoSync AI mobile Git client (Flutter + Rust core) for bi-directional repository synchronization, in-app diffing, AI code assistance with secret redaction, and background sync.
- Stack: Flutter 3.35+, Dart, Rust stable, flutter_rust_bridge 2.x, libgit2, Android SDK / NDK
- Target users / market: Mobile developers syncing local and remote Git repositories

## Commands (run from the workspace root with absolute paths)
- Flutter dependencies: `flutter pub get` (or `fvm flutter pub get`)
- Analyze: `flutter analyze`
- Tests: `flutter test`
- Rust build / check: `cargo check --manifest-path rust/Cargo.toml`
- Bridge generator: `flutter_rust_bridge_codegen generate`
- Language check (must print nothing before each commit):
  `git -C C:/Users/vladv/projects/RepoAutoFix diff --cached | grep -nP '[\x{4e00}-\x{9fff}]' || true`

## Google Jules Agent Integration
- **Configuration:** `.jules/config.json` specifies `gemini-2.5-pro` model, `flutter pub get` setup, and `flutter analyze` / `flutter test` verification.
- **Rules & Guardrails:** `.jules/rules.md` enforces Rust FFI memory safety, flutter_rust_bridge integrity, and zero secret leakage.
- **CI/CD Automation:** `.github/workflows/jules.yml` triggers automated Flutter analyze and Cargo check on labeled issues or pull requests.

## Boundaries
- Workspace: C:\Users\vladv\projects\RepoAutoFix
- Allowed write paths: `lib/`, `rust/src/`, `test/`, `docs/`, `WORKLOG.md`, `STUCK.md`, `STATUS.md`, `requests/`
- Read-only: `android/app/build.gradle`, `rust/Cargo.lock`, license notices
- Project red lines: NEVER commit `lib/constant/secrets.dart` or API keys; keep `allowBackup="false"` to prevent credentials leakage in system backups.

## Conventions
- Dart: Effective Dart, clean separation between Flutter UI and Rust FFI bridge
- One feature per commit; commit message format: `T<id>: <what>` or conventional commit

## AI Agent Skills & MCP Integration (2026)

### Recommended Skill Collections
```bash
# Skill management
npm install -g @skillkit/cli && skillkit init
skillkit recommend

# Flutter / Rust / Git / AI skills
npx skills add seb1n/awesome-ai-agent-skills --skill flutter,rust,git,ai
npx skills add thongdn-it/react-agent-skills --skill flutter,rust

# Security scan before install
npm install -g @nvidia/skillspector
skillspector scan <repo-url>
```

### MCP Server Configuration
Configure in agent settings (`.claude/settings.json`, `kilo.jsonc`):
```json
{
  "mcpServers": {
    "browser": "browser-use/browser-use",
    "openregister": "openregister/openregister-sdk",
    "github": "github/github-mcp-server",
    "gitlab": "gitlab/gitlab-mcp"
  }
}
```

### German API Integration Points
| API | MCP/REST | Use Case | Config |
|---|---|---|---|
| OpenRegister | REST + SDK | GitHub/GitLab org verification | `OPENREGISTER_API_KEY` |
| Bundestag DIP | REST | Compliance reference (UrhG, TDDDG, DSGVO) | No auth |
| Gesetze im Internet | REST | Legal reference for licensing | No auth |
| Feiertage | REST | Background sync scheduling | No auth |
| OpenPlz | REST | Geo-distributed team support | No auth |

### Subagent Delegation (Kilo Multi-Agent)
Use native `task(agent="...", ...)` for specialized work:
- `task(agent="architect", ...)` — Before new modules, FFI bridge changes, sync protocol changes
- `task(agent="debugger", ...)` — Test failures, Rust FFI crashes, Flutter analyze issues
- `task(agent="revisor", ...)` — Pre-commit: security scan, secret redaction audit, diff analysis
- `task(agent="security-reviewer", ...)` — Secret redaction validation, OAuth flow audit

### Verification Gates (Required per Commit)
```bash
flutter analyze && flutter test && cargo check --manifest-path rust/Cargo.toml
# Secret scanning (critical for this project!)
npx -y gitleaks detect --no-git -v
```