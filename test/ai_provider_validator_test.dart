import 'package:flutter_test/flutter_test.dart';
import 'package:GitSync/api/ai_provider_validator.dart';

void main() {
  group('validateSelfHostedEndpoint', () {
    test('accepts HTTPS public endpoints', () {
      expect(validateSelfHostedEndpoint('https://ai.example.com/v1'), isNull);
    });

    test('allows HTTP for local and private model servers', () {
      for (final endpoint in [
        'http://localhost:11434/v1',
        'http://127.0.0.1:8080/v1',
        'http://10.0.0.5:8000/v1',
        'http://192.168.1.25:1234/v1',
        'http://172.20.10.2:9000/v1',
      ]) {
        expect(validateSelfHostedEndpoint(endpoint), isNull, reason: '$endpoint should be allowed');
      }
    });

    test('rejects cleartext public hosts and URI-embedded credentials', () {
      expect(validateSelfHostedEndpoint('http://ai.example.com/v1'), isNotNull);
      expect(validateSelfHostedEndpoint('https://user:password@ai.example.com/v1'), isNotNull);
      expect(validateSelfHostedEndpoint('https://ai.example.com/v1?key=secret'), isNotNull);
    });
  });
}
