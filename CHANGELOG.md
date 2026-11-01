# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Updated Dart SDK environment constraint in `pubspec.yaml` from rigid `sdk: 3.9.0` to standard range `sdk: ">=3.9.0 <4.0.0"` and `flutter: ">=3.35.0"`.
- Upgraded `re_editor` dependency from `^0.8.0` to `^0.10.0` to resolve `TextInputClient.onFocusReceived` Flutter 3.44+ breaking API change.
- Decoupled `lib/api/ai_provider_validator.dart` from heavy `helper.dart` with dedicated HTTP timeout client, isolating unit test suites from native bridge (`frb_generated.dart`) requirements.

### Added
- Comprehensive test coverage for AI endpoint validation (`validateSelfHostedEndpoint`) and sensitive credential redaction (`isSensitiveAiPath`, `redactAiSecrets`) passing 9/9 unit tests.
