# HANDOFF: RepoAutoFix

## Mission
Deliver a reliable, private mobile Git synchronization client combining Rust libgit2 performance with on-device AI repo assistance, secure OAuth flows, and background file syncing.

## Boundaries
- Allowed write paths: `lib/`, `rust/src/`, `test/`, `docs/`, WORKLOG.md, STUCK.md, STATUS.md, requests/
- Do not touch: upstream license notices (`LICENSE.md`), release keystores
- Decisions reserved for me: OAuth provider registrations, upstream GitSync rebase policies

## Environment
- OS: Windows 11 (Git Bash). Runtimes: Flutter SDK, Dart, Rust stable (cargo), Android NDK.
- External services: GitHub, GitLab, Gitea OAuth, AI model providers (OpenAI, Anthropic, Google)

## Finish line
Repository default branch is `main`, clean git status, and diagnostics pass.

## Queue
### T1: Documentation and workspace standardization
- Goal: Establish AGENTS.md, HANDOFF.md, ensure secrets redaction guidelines and FFI boundaries are documented.
- Context: Cloned into unified `projects/` directory, default branch confirmed as main.
- Constraints: Read-only check.
- Done when: `AGENTS.md` and `HANDOFF.md` present, working directory clean on main.
- Not acceptable: committing real API keys or OAuth secrets.
