# Jules Agent Rules: RepoAutoFix (RepoSync AI)

## Architecture & Verification
1. **Rust FFI & Memory Safety Invariant:**
   - All FFI communication between Dart and Rust routes through `flutter_rust_bridge` 2.x.
   - Rust code must remain strictly safe: no unmanaged pointer dereferences or memory leaks across FFI boundaries.
   - When updating bridge types, regenerate code via `flutter_rust_bridge_codegen generate`.
2. **Secrets & Security Invariant:**
   - Never commit `lib/constant/secrets.dart`, keystore properties, or OAuth client secrets.
   - Ensure Android `allowBackup="false"` remains configured in `AndroidManifest.xml` to prevent credential harvesting.
3. **Quality Gates:**
   - `flutter analyze` must pass with zero issues.
   - `cargo check --manifest-path rust/Cargo.toml` must compile without errors.
   - All tests in `test/` must pass.
4. **Git Discipline:**
   - Target branch is `main`. Commit messages must follow conventional format (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`).
