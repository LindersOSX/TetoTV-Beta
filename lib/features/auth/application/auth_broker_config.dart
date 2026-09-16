import 'package:anime_tv/core/config/app_config.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(),
);

const authBrokerUrlStorageKey = 'auth_broker_base_url';

// SHA-256 of the retired production broker host. Keeping only the digest lets
// upgraded installs migrate an old secure-storage override without shipping
// the obsolete host as a usable endpoint in the APK.
const _retiredAuthBrokerHostDigest =
    'c1b1c05446512fd0caf6636ce467d13d3fb001b8810799f842d83a8880c00a5c';

class AuthBrokerNotConfigured implements Exception {
  const AuthBrokerNotConfigured();

  @override
  String toString() =>
      'Tracker QR login requires the TetoTV account companion.';
}

String? normalizeAuthBrokerBaseUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri
      .replace(
        path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
        query: null,
        fragment: null,
      )
      .toString();
}

Future<String?> effectiveAuthBrokerBaseUrl(FlutterSecureStorage storage) async {
  final saved = await storage.read(key: authBrokerUrlStorageKey);
  final savedUrl = normalizeAuthBrokerBaseUrl(saved ?? '');
  final configured = normalizeAuthBrokerBaseUrl(AppConfig.authBrokerBaseUrl);
  if (savedUrl == null) return configured;
  final savedHost = Uri.parse(savedUrl).host.toLowerCase();
  final isRetiredProductionHost =
      sha256.convert(savedHost.codeUnits).toString() ==
      _retiredAuthBrokerHostDigest;
  if (!isRetiredProductionHost) return savedUrl;

  // This is a one-way, best-effort migration. A storage write failure must not
  // send an upgraded user back to the retired endpoint for this session.
  try {
    if (configured == null) {
      await storage.delete(key: authBrokerUrlStorageKey);
    } else {
      await storage.write(key: authBrokerUrlStorageKey, value: configured);
    }
  } catch (_) {
    // The configured in-memory replacement remains authoritative below.
  }
  return configured;
}
