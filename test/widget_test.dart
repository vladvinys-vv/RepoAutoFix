// Harness smoke test.
//
// The original Flutter counter-app template could never run here (this app
// has no counter and booting it in a test would need plugins/platform setup),
// but a Dart file under test/ must expose main() for `flutter test` to load
// it. Keep this placeholder green and put real coverage in dedicated test
// files (see ai_provider_validator_test.dart, ai_sensitive_path_test.dart).
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('test harness is wired up', () {
    expect(2 + 2, 4);
  });
}
