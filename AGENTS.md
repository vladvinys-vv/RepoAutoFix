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
