import 'dart:convert';

import 'package:GitSync/api/helper.dart';
import 'package:http/http.dart' as http;

enum AiProvider { anthropic, openai, google, selfHosted }

Future<String?> validateAiApiKey({required AiProvider provider, required String apiKey, String? endpoint}) async {
  if (apiKey.trim().isEmpty) return 'API key cannot be empty';
  if (provider == AiProvider.selfHosted) {
    if (endpoint == null || endpoint.trim().isEmpty) return 'Endpoint URL is required for self-hosted providers';
    final endpointError = validateSelfHostedEndpoint(endpoint);
    if (endpointError != null) return endpointError;
  }

  try {
    final http.Response response;
    switch (provider) {
      case AiProvider.anthropic:
        response = await httpGet(Uri.parse('https://api.anthropic.com/v1/models'), headers: {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'});
      case AiProvider.openai:
        response = await httpGet(Uri.parse('https://api.openai.com/v1/models'), headers: {'Authorization': 'Bearer $apiKey'});
      case AiProvider.google:
        response = await httpGet(Uri.parse('https://generativelanguage.googleapis.com/v1/models'), headers: {'x-goog-api-key': apiKey});
      case AiProvider.selfHosted:
        final normalized = normalizeEndpoint(endpoint!);
        response = await httpGet(Uri.parse('$normalized/models'), headers: {'Authorization': 'Bearer $apiKey'});
    }

    if (response.statusCode == 408) return 'Connection timed out';
    if (response.statusCode == 401 || response.statusCode == 403) return 'Invalid API key';
    if (response.statusCode >= 200 && response.statusCode < 300) return null;
    return 'Unexpected response (${response.statusCode})';
  } catch (e) {
    return 'Connection failed: ${e.toString()}';
  }
}

String normalizeEndpoint(String endpoint) {
  var value = endpoint.trim();
  if (value.endsWith('/')) value = value.substring(0, value.length - 1);
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'http://$value';
  }
  return value;
}

/// Prevent sending a self-hosted API key over cleartext HTTP to a public host.
/// Plain HTTP remains available for local/private-network inference servers.
String? validateSelfHostedEndpoint(String endpoint) {
  final uri = Uri.tryParse(normalizeEndpoint(endpoint));
  if (uri == null || uri.host.isEmpty) return 'Enter a valid endpoint URL';
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    return 'Endpoint URLs must not contain credentials, query parameters, or fragments';
  }
  if (uri.scheme == 'https') return null;
  if (uri.scheme != 'http') return 'Endpoint must use HTTPS, or HTTP on a local/private network';
  if (_isLocalOrPrivateHost(uri.host)) return null;
  return 'Use HTTPS for public endpoints. HTTP is allowed only for localhost or a private network';
}

bool _isLocalOrPrivateHost(String rawHost) {
  final host = rawHost.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host == '::1' || host.startsWith('fe80:')) {
    return true;
  }

  final octets = host.split('.').map((part) => int.tryParse(part)).toList();
  if (octets.length != 4 || octets.any((octet) => octet == null || octet < 0 || octet > 255)) return false;
  final first = octets[0]!;
  final second = octets[1]!;
  return first == 10 ||
      first == 127 ||
      (first == 192 && second == 168) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 169 && second == 254);
}

AiProvider? aiProviderFromString(String? name) {
  switch (name) {
    case 'Anthropic':
      return AiProvider.anthropic;
    case 'OpenAI':
      return AiProvider.openai;
    case 'Google':
      return AiProvider.google;
    case 'Self-hosted':
      return AiProvider.selfHosted;
    default:
      return null;
  }
}

Future<(List<String>, String?)> fetchAvailableModels({required AiProvider provider, required String apiKey, String? endpoint}) async {
  if (provider == AiProvider.selfHosted) {
    final endpointError = validateSelfHostedEndpoint(endpoint ?? '');
    if (endpointError != null) return (<String>[], endpointError);
  }

  try {
    final http.Response response;
    switch (provider) {
      case AiProvider.anthropic:
        response = await httpGet(Uri.parse('https://api.anthropic.com/v1/models'), headers: {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'});
      case AiProvider.openai:
        response = await httpGet(Uri.parse('https://api.openai.com/v1/models'), headers: {'Authorization': 'Bearer $apiKey'});
      case AiProvider.google:
        response = await httpGet(Uri.parse('https://generativelanguage.googleapis.com/v1/models'), headers: {'x-goog-api-key': apiKey});
      case AiProvider.selfHosted:
        final normalized = normalizeEndpoint(endpoint!);
        response = await httpGet(Uri.parse('$normalized/models'), headers: {'Authorization': 'Bearer $apiKey'});
    }

    if (response.statusCode == 408) return (<String>[], 'Connection timed out. Check your network and try again.');
    if (response.statusCode == 401 || response.statusCode == 403) return (<String>[], 'Invalid API key. Please check your key and try again.');
    if (response.statusCode == 429) return (<String>[], 'Rate limited. Please wait a moment and try again.');
    if (response.statusCode < 200 || response.statusCode >= 300) return (<String>[], 'Failed to load models (${response.statusCode})');

    final json = jsonDecode(utf8.decode(response.bodyBytes));
    switch (provider) {
      case AiProvider.selfHosted:
      case AiProvider.openai:
      case AiProvider.anthropic:
        final data = json['data'] as List?;
        if (data == null) return (<String>[], null);
        return (data.map<String>((model) => model['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList(), null);
      case AiProvider.google:
        final models = json['models'] as List?;
        if (models == null) return (<String>[], null);
        return (models.map<String>((model) => (model['name']?.toString() ?? '').replaceFirst('models/', '')).where((id) => id.isNotEmpty).toList(), null);
    }
  } catch (e) {
    final message = e.toString();
    if (message.contains('SocketException')) return (<String>[], 'Network error. Check your connection.');
    return (<String>[], 'Connection failed: $message');
  }
}

String aiProviderToString(AiProvider provider) {
  switch (provider) {
    case AiProvider.anthropic:
      return 'Anthropic';
    case AiProvider.openai:
      return 'OpenAI';
    case AiProvider.google:
      return 'Google';
    case AiProvider.selfHosted:
      return 'Self-hosted';
  }
}
