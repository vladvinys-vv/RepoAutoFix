# HANDOFF: RepoAutoFix

## Mission
Deliver a reliable, private mobile Git synchronization client combining Rust libgit2 performance with on-device AI repo assistance, secure OAuth flows, and background file syncing.

## Current Status (October 2026)
- **Unified Location:** Standardized at `C:\Users\vladv\projects\RepoAutoFix`.
- **Default Branch:** `main` (clean, synchronized with `origin/main`).
- **Google Jules Agent Integration:** Integrated `.jules/config.json`, `.jules/rules.md`, and `.github/workflows/jules.yml`.
- **Hygiene & Standards:**
  - Modern Flutter + Rust codebase.
  - Added `AGENTS.md` and this `HANDOFF.md`.

## Boundaries
- Allowed write paths: `lib/`, `rust/src/`, `test/`, `docs/`, WORKLOG.md, STUCK.md, STATUS.md, requests/
- Do not touch: upstream license notices (`LICENSE.md`), release keystores
- Decisions reserved for me: OAuth provider registrations, upstream GitSync rebase policies

## Environment
- OS: Windows 11 (Git Bash). Runtimes: Flutter SDK, Dart, Rust stable (cargo), Android NDK.
- External services: GitHub, GitLab, Gitea OAuth, AI model providers (OpenAI, Anthropic, Google)

## Verification Commands
```bash
flutter analyze
cargo check --manifest-path rust/Cargo.toml
flutter test
```
