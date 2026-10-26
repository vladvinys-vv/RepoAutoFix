/// Helpers that prevent obvious credential files and values from being sent to
/// an AI provider through repository tools.
///
/// This is defense in depth, not a substitute for reviewing what is shared:
/// secrets can also live in files with ordinary names.
bool isSensitiveAiPath(String path) {
  final segments = path
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (segments.isEmpty) return false;

  const sensitiveDirectories = {'.ssh', '.aws', '.azure', '.kube', '.gnupg', '.docker', 'secrets', 'credentials', 'private_keys'};
  if (segments.any((segment) => sensitiveDirectories.contains(segment.toLowerCase()))) {
    return true;
  }

  const safeTemplateSuffixes = ['.example', '.sample', '.template', '.dist'];
  for (final segment in segments) {
    final name = segment.toLowerCase();
    if (safeTemplateSuffixes.any(name.endsWith)) continue;

    if (name == '.env' || name.startsWith('.env.') || name.endsWith('.env')) return true;
    if (name == '.netrc' || name == '.npmrc' || name == '.pypirc' || name == '.git-credentials' || name == 'credentials') return true;
    if (name.startsWith('credentials.') || name.startsWith('secret.') || name.startsWith('secrets.')) return true;
    if (name.startsWith('id_rsa') || name.startsWith('id_ed25519') || name.startsWith('id_ecdsa') || name.startsWith('id_dsa')) {
      return true;
    }
    if (name.startsWith('service-account') || name.startsWith('firebase-adminsdk')) return true;
    if (name.endsWith('.pem') ||
        name.endsWith('.key') ||
        name.endsWith('.p12') ||
        name.endsWith('.pfx') ||
        name.endsWith('.p8') ||
        name.endsWith('.jks') ||
        name.endsWith('.keystore') ||
        name.endsWith('.tfstate') || name.contains('.tfstate.')) {
      return true;
    }
  }

  return false;
}

/// Redact common credential formats from otherwise ordinary text files before
/// they are included in an AI tool response.
String redactAiSecrets(String text) {
  var redacted = text.replaceAll(
    RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'),
    '[REDACTED PRIVATE KEY]',
  );
  redacted = redacted.replaceAll(RegExp(r'\bAKIA[0-9A-Z]{16}\b'), '[REDACTED AWS ACCESS KEY]');
  redacted = redacted.replaceAll(RegExp(r'\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})\b'), '[REDACTED TOKEN]');
  redacted = redacted.replaceAll(RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{16,}', caseSensitive: false), 'Bearer [REDACTED TOKEN]');
  redacted = redacted.replaceAll(RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'), '[REDACTED JWT]');

  final assignmentPattern = RegExp(
    r'''(["']?\b(?:[A-Z0-9_]*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|REFRESH[_-]?TOKEN|AUTHORIZATION|CLIENT[_-]?SECRET|PASSWORD|PASSWD|PRIVATE[_-]?KEY|SECRET)[A-Z0-9_]*)\b["']?\s*[:=]\s*)(["']?)([^\r\n,"'}]+)(["']?)''',
    caseSensitive: false,
    multiLine: true,
  );
  redacted = redacted.replaceAllMapped(
    assignmentPattern,
    (match) => '${match.group(1)}${match.group(2)}[REDACTED]${match.group(4)}',
  );
  return redacted;
}
