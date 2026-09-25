import 'package:flutter_test/flutter_test.dart';
import 'package:GitSync/api/ai_sensitive_path.dart';

void main() {
  group('isSensitiveAiPath', () {
    test('blocks common credential files and directories', () {
      for (final path in [
        '.env',
        'deploy/.env.production',
        '.ssh/id_ed25519',
        '.aws/credentials',
        'certs/server.pem',
        'secrets/prod.key',
        'terraform/terraform.tfstate',
        'service-account-prod.json',
      ]) {
        expect(isSensitiveAiPath(path), isTrue, reason: '$path should be protected');
      }
    });

    test('allows templates and ordinary source files', () {
      for (final path in [
        '.env.example',
        'config/secrets.yaml.template',
        'lib/api/secret_manager.dart',
        'README.md',
      ]) {
        expect(isSensitiveAiPath(path), isFalse, reason: '$path should remain available');
      }
    });

    test('normalizes Windows separators before checking', () {
      expect(isSensitiveAiPath('config\\.env.production'), isTrue);
    });
  });

  group('redactAiSecrets', () {
    test('redacts common assigned credentials and tokens', () {
      final output = redactAiSecrets('''
API_KEY="personal-value-123456"
{"client_secret": "dont-send-this-value"}
Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456
''');

      expect(output, isNot(contains('personal-value-123456')));
      expect(output, isNot(contains('dont-send-this-value')));
      expect(output, isNot(contains('abcdefghijklmnopqrstuvwxyz123456')));
      expect(output, contains('[REDACTED]'));
    });

    test('redacts private key blocks', () {
      final output = redactAiSecrets('''
-----BEGIN PRIVATE KEY-----
private-material
-----END PRIVATE KEY-----
''');
      expect(output, contains('[REDACTED PRIVATE KEY]'));
      expect(output, isNot(contains('private-material')));
    });
  });
}
