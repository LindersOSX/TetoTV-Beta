import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('provider-generic debrid failover', () {
    test('retains cache-miss failover for every service', () {
      for (final service in DebridService.values) {
        expect(
          isTerminalDebridFailoverFailure(DebridCacheMissException(service)),
          isFalse,
          reason: service.displayName,
        );
      }
    });

    test('retains release-local failover for every provider', () {
      final failures = <String, DebridProviderFailure>{
        'Real-Debrid': RealDebridException.fromApi(code: 35),
        'TorBox': const TorBoxException(
          'Not cached',
          code: 'DOWNLOAD_NOT_CACHED',
        ),
        'Premiumize': const PremiumizeException(
          'Source not found',
          code: 'not_found',
        ),
        'AllDebrid': const AllDebridException(
          'Invalid magnet',
          code: 'MAGNET_INVALID_URI',
        ),
      };

      for (final MapEntry(key: provider, value: failure) in failures.entries) {
        expect(
          failure.failureCategory,
          DebridFailureCategory.releaseUnavailable,
          reason: provider,
        );
        expect(
          isTerminalDebridFailoverFailure(failure),
          isFalse,
          reason: provider,
        );
      }
    });

    test('stops authentication failures for every provider', () {
      _expectTerminalProviderFailures({
        'Real-Debrid': RealDebridException.fromApi(code: 8, httpStatus: 401),
        'TorBox': const TorBoxException('Bad token', code: 'AUTH_ERROR'),
        'Premiumize': const PremiumizeException(
          'Bad token',
          code: 'authentication_failed',
        ),
        'AllDebrid': const AllDebridException(
          'Bad token',
          code: 'AUTH_BAD_APIKEY',
        ),
      }, DebridFailureCategory.authorization);
    });

    test('stops account failures for every provider', () {
      _expectTerminalProviderFailures({
        'Real-Debrid': RealDebridException.fromApi(code: 21),
        'TorBox': const TorBoxException(
          'Active download limit',
          code: 'ACTIVE_LIMIT',
        ),
        'Premiumize': const PremiumizeException(
          'Fair use limit reached',
          code: 'fair_use_limit_reached',
        ),
        'AllDebrid': const AllDebridException(
          'Too many active magnets',
          code: 'MAGNET_TOO_MANY_ACTIVE',
        ),
      }, DebridFailureCategory.account);
    });

    test('stops rate-limit failures for every provider', () {
      _expectTerminalProviderFailures({
        'Real-Debrid': RealDebridException.fromApi(code: 34),
        'TorBox': const TorBoxException(
          'Too many requests',
          code: 'RATE_LIMITED',
        ),
        'Premiumize': const PremiumizeException(
          'Too many requests',
          code: 'too_many_requests',
        ),
        'AllDebrid': const AllDebridException(
          'Too many requests',
          code: 'RATE_LIMITED',
        ),
      }, DebridFailureCategory.rateLimited);
    });

    test('stops provider/service failures for every provider', () {
      _expectTerminalProviderFailures({
        'Real-Debrid': RealDebridException.fromApi(code: 18),
        'TorBox': const TorBoxException(
          'Service unavailable',
          code: 'SERVICE_UNAVAILABLE',
        ),
        'Premiumize': const PremiumizeException(
          'Network unavailable',
          code: 'network_error',
        ),
        'AllDebrid': const AllDebridException(
          'No server',
          code: 'MAGNET_NO_SERVER',
        ),
      }, DebridFailureCategory.serviceUnavailable);
    });

    test('stops pre-client access and cleanup failures', () {
      expect(
        isTerminalDebridFailoverFailure(
          const DebridProviderAccessException(DebridService.torBox),
        ),
        isTrue,
      );
      expect(
        isTerminalDebridFailoverFailure(
          const DebridCleanupFailureException(DebridService.realDebrid),
        ),
        isTrue,
      );
    });

    test('keeps unclassified release/runtime errors candidate-local', () {
      expect(
        isTerminalDebridFailoverFailure(Exception('broken release')),
        isFalse,
      );
    });
  });
}

void _expectTerminalProviderFailures(
  Map<String, DebridProviderFailure> failures,
  DebridFailureCategory expectedCategory,
) {
  for (final MapEntry(key: provider, value: failure) in failures.entries) {
    expect(failure.failureCategory, expectedCategory, reason: provider);
    expect(isTerminalDebridFailoverFailure(failure), isTrue, reason: provider);
  }
}
