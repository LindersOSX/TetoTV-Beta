import 'dart:async';

import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRef extends Fake implements Ref {
  @override
  void invalidate(ProviderOrFamily provider) {}
}

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'token refresh failure finishes loading and reports the account',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.myAnimeList.tokenStorageKey: 'expired-token',
        TrackingProvider.myAnimeList.expiresAtStorageKey: DateTime.utc(
          2025,
        ).toIso8601String(),
      });
      final tokenService = TrackingTokenService(
        storage,
        now: () => DateTime.utc(2026),
      );
      final controller = TrackingAccountsController(_FakeRef(), tokenService);

      await controller.load();

      expect(controller.state.isLoading, isFalse);
      expect(controller.state.usernames, isEmpty);
      expect(
        controller.state.errors[TrackingProvider.myAnimeList],
        contains('session expired'),
      );
    },
  );

  test('loads bounded AniList and MAL profile statistics', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.anilist.tokenStorageKey: 'anilist-access',
      TrackingProvider.myAnimeList.tokenStorageKey: 'mal-access',
    });
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          if (options.uri.host == 'graphql.anilist.co') {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: const {
                  'data': {
                    'Viewer': {
                      'name': 'TetoFan',
                      'avatar': {'large': 'https://img.anili.st/avatar.png'},
                      'statistics': {
                        'anime': {
                          'count': 120,
                          'episodesWatched': 2400,
                          'minutesWatched': 48000,
                          'meanScore': 82.4,
                        },
                      },
                    },
                  },
                },
              ),
            );
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'name': 'MALFan',
                'picture': 'https://cdn.myanimelist.net/avatar.jpg',
                'anime_statistics': {
                  'num_items': 88,
                  'num_episodes': 1700,
                  'num_days_watched': 41.5,
                  'mean_score': 8.1,
                },
              },
            ),
          );
        },
      ),
    );
    final controller = TrackingAccountsController(
      _FakeRef(),
      TrackingTokenService(storage),
      dio: dio,
    );

    await controller.load();

    final anilist = controller.state.profiles[TrackingProvider.anilist]!;
    expect(anilist.username, 'TetoFan');
    expect(anilist.avatarUrl, 'https://img.anili.st/avatar.png');
    expect(anilist.animeCount, 120);
    expect(anilist.episodesWatched, 2400);
    expect(anilist.minutesWatched, 48000);
    expect(anilist.meanScore, 82.4);
    final mal = controller.state.profiles[TrackingProvider.myAnimeList]!;
    expect(mal.username, 'MALFan');
    expect(mal.animeCount, 88);
    expect(mal.episodesWatched, 1700);
    expect(mal.minutesWatched, 59760);
    expect(mal.meanScore, 8.1);
    expect(controller.state.usernames[TrackingProvider.anilist], 'TetoFan');
    expect(
      controller.state.savedProfiles[TrackingProvider.anilist]?.single.username,
      'TetoFan',
    );
    expect(anilist.slotId, isNotNull);
    expect(
      controller.state.activeProfileIds[TrackingProvider.anilist],
      anilist.slotId,
    );
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
    }
    expect(requests.last.queryParameters['fields'], 'picture,anime_statistics');
  });

  test('rejects unsafe tracker avatar URLs', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.anilist.tokenStorageKey: 'anilist-access',
      TrackingProvider.myAnimeList.tokenStorageKey: 'mal-access',
    });
    for (final unsafeAvatar in <String>[
      'http://example.com/avatar.png',
      'https://localhost/avatar.png',
      'https://printer.local/avatar.png',
      'https://127.0.0.1/avatar.png',
      'https://10.0.0.1/avatar.png',
      'https://172.16.1.1/avatar.png',
      'https://192.168.1.1/avatar.png',
      'https://169.254.1.1/avatar.png',
      'https://[::1]/avatar.png',
      'https://[fe80::1]/avatar.png',
      'https://user:password@example.com/avatar.png',
      'https://example.com/avatar.png#fragment',
      'https://example.com:8443/avatar.png',
      'https://bad_host.example/avatar.png',
      'https://single-label/avatar.png',
    ]) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.host == 'graphql.anilist.co') {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'data': {
                      'Viewer': {
                        'name': 'AniList user',
                        'avatar': {'large': unsafeAvatar},
                      },
                    },
                  },
                ),
              );
              return;
            }
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {'name': 'MAL user', 'picture': unsafeAvatar},
              ),
            );
          },
        ),
      );
      final controller = TrackingAccountsController(
        _FakeRef(),
        TrackingTokenService(storage),
        dio: dio,
      );

      await controller.load();

      expect(
        controller.state.profiles[TrackingProvider.anilist]?.avatarUrl,
        isNull,
        reason: unsafeAvatar,
      );
      expect(
        controller.state.profiles[TrackingProvider.myAnimeList]?.avatarUrl,
        isNull,
        reason: unsafeAvatar,
      );
      controller.dispose();
    }
  });

  test(
    'disconnect hides the account synchronously before storage completes',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'data': {
                  'Viewer': {'name': 'TetoFan'},
                },
              },
            ),
          ),
        ),
      );
      final tokenService = _BlockingClearTokenService(storage);
      final controller = TrackingAccountsController(
        _FakeRef(),
        tokenService,
        dio: dio,
      );
      await controller.load();
      expect(controller.state.isConnected(TrackingProvider.anilist), isTrue);

      final disconnect = controller.disconnect(TrackingProvider.anilist);

      expect(tokenService.clearStarted.isCompleted, isTrue);
      expect(controller.state.usernames, isEmpty);
      expect(controller.state.profiles, isEmpty);
      tokenService.allowClear.complete();
      await disconnect;
      expect(controller.state.usernames, isEmpty);
    },
  );
}

class _BlockingClearTokenService extends TrackingTokenService {
  _BlockingClearTokenService(super.storage);

  final clearStarted = Completer<void>();
  final allowClear = Completer<void>();
  bool _connected = true;

  @override
  Future<String?> accessToken(TrackingProvider provider) async =>
      provider == TrackingProvider.anilist && _connected ? 'token' : null;

  @override
  Future<void> clear(TrackingProvider provider) async {
    clearStarted.complete();
    await allowClear.future;
    _connected = false;
  }
}
