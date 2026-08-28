import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/data/real_debrid_oauth_client.dart';
import 'package:anime_tv/features/settings/application/real_debrid_settings_controller.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final debridTokenServiceProvider = Provider<DebridTokenService>(
  (ref) => DebridTokenService(ref.watch(secureStorageProvider)),
);

/// Returns a usable access token for a configured debrid service.
///
/// Direct API keys for TorBox, AllDebrid, and Premiumize do not expire on a
/// schedule known to TetoTV. Real-Debrid device-flow access tokens do, so every
/// playback entry point must come through this service instead of reading
/// secure storage directly. Refreshes are single-flight to prevent repeated
/// remote-control activation from rotating the same refresh token twice.
class DebridTokenService {
  DebridTokenService(
    this._storage, {
    RealDebridOAuthClient? realDebridOAuthClient,
    DateTime Function()? now,
  }) : _realDebridOAuthClient =
           realDebridOAuthClient ?? RealDebridOAuthClient(),
       _now = now ?? DateTime.now;

  final FlutterSecureStorage _storage;
  final RealDebridOAuthClient _realDebridOAuthClient;
  final DateTime Function() _now;
  Future<String?>? _realDebridRequest;

  Future<String?> accessToken(DebridService service) {
    if (service != DebridService.realDebrid) {
      return _readToken(service.tokenStorageKey);
    }

    final activeRequest = _realDebridRequest;
    if (activeRequest != null) return activeRequest;

    final request = _realDebridAccessToken();
    _realDebridRequest = request;
    return request.whenComplete(() {
      if (identical(_realDebridRequest, request)) {
        _realDebridRequest = null;
      }
    });
  }

  Future<String?> _realDebridAccessToken() async {
    final currentToken = await _readToken(realDebridTokenStorageKey);
    if (currentToken == null) return null;

    final expiryValue = await _storage.read(
      key: realDebridAccessExpiryStorageKey,
    );
    final expiry = DateTime.tryParse(expiryValue ?? '')?.toUtc();
    final now = _now().toUtc();
    if (expiry == null || expiry.isAfter(now.add(const Duration(minutes: 5)))) {
      return currentToken;
    }

    final values = await Future.wait([
      _storage.read(key: realDebridClientIdStorageKey),
      _storage.read(key: realDebridClientSecretStorageKey),
      _storage.read(key: realDebridRefreshTokenStorageKey),
    ]);
    if (values.any((value) => value == null || value.trim().isEmpty)) {
      if (expiry.isAfter(now)) return currentToken;
      throw StateError(
        'Real-Debrid authorization expired. Reconnect Real-Debrid in Accounts.',
      );
    }

    try {
      final tokens = await _realDebridOAuthClient.refresh(
        clientId: values[0]!,
        clientSecret: values[1]!,
        refreshToken: values[2]!,
      );
      await _storage.write(
        key: realDebridRefreshTokenStorageKey,
        value: tokens.refreshToken,
      );
      await _storage.write(
        key: realDebridTokenStorageKey,
        value: tokens.accessToken,
      );
      await _storage.write(
        key: realDebridAccessExpiryStorageKey,
        value: tokens.expiresAt.toUtc().toIso8601String(),
      );
      return tokens.accessToken;
    } catch (_) {
      // A refresh can fail briefly before the current token actually expires.
      // Keep playback available during that grace period, but never return a
      // token that is already known to be expired.
      if (expiry.isAfter(now)) return currentToken;
      rethrow;
    }
  }

  Future<String?> _readToken(String key) async {
    final token = (await _storage.read(key: key))?.trim();
    return token == null || token.isEmpty ? null : token;
  }
}
