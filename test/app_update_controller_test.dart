import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  group('version and channel policy', () {
    test('compares release versions and Android build numbers numerically', () {
      expect(compareAppVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareAppVersions('v1.7.3', '1.7.3'), 0);
      expect(compareAppVersions('1.7.2', '1.7.3'), lessThan(0));
      expect(compareAppVersions('1.9.0+34901', '1.9.0+34900'), greaterThan(0));
      expect(appVersionCode('TetoTV v1.9.0+34901'), 34901);
      expect(normalizeAppVersion('TetoTV v1.9.0+34901'), '1.9.0+34901');
    });

    test('allows intentional Public and Beta family switching', () {
      expect(
        shouldOfferAppRelease(
          currentVersion: '2.0.5+410001',
          releaseVersion: '1.0.2',
          channel: AppUpdateChannel.public,
        ),
        isTrue,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '1.0.2+410001',
          releaseVersion: '2.0.5',
          channel: AppUpdateChannel.beta,
        ),
        isTrue,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '1.0.2+410001',
          releaseVersion: '1.0.2',
          channel: AppUpdateChannel.public,
        ),
        isFalse,
      );
    });

    test('known Android build metadata blocks impossible downgrades', () {
      expect(
        isKnownAndroidVersionDowngrade(
          currentVersion: '2.0.31+410008',
          releaseVersionCode: 410007,
        ),
        isTrue,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '2.0.31+410008',
          releaseVersion: '1.0.4',
          releaseVersionCode: 410001,
          channel: AppUpdateChannel.public,
        ),
        isFalse,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '2.0.31+410008',
          releaseVersion: '1.0.5',
          releaseVersionCode: 410008,
          channel: AppUpdateChannel.public,
        ),
        isTrue,
        reason: 'Equal-build signed channel counterparts remain eligible.',
      );
    });

    test('infers an unsaved update channel from the installed APK family', () {
      expect(
        resolveAppUpdateChannel(
          storedValue: null,
          installedVersion: '2.0.28+410005',
        ),
        AppUpdateChannel.beta,
      );
      expect(
        resolveAppUpdateChannel(
          storedValue: null,
          installedVersion: '1.0.4+410001',
        ),
        AppUpdateChannel.public,
      );
      expect(
        resolveAppUpdateChannel(storedValue: null, installedVersion: 'unknown'),
        AppUpdateChannel.public,
      );
    });

    test('keeps an explicitly stored channel across APK families', () {
      expect(
        resolveAppUpdateChannel(
          storedValue: AppUpdateChannel.public.name,
          installedVersion: '2.0.28+410005',
        ),
        AppUpdateChannel.public,
      );
      expect(
        resolveAppUpdateChannel(
          storedValue: AppUpdateChannel.beta.name,
          installedVersion: '1.0.4+410001',
        ),
        AppUpdateChannel.beta,
      );
    });

    test('offers Beta 2.0.22 over 2.0.21 at the same Android code', () {
      expect(
        shouldOfferAppRelease(
          currentVersion: '2.0.21+410001',
          releaseVersion: '2.0.22',
          channel: AppUpdateChannel.beta,
        ),
        isTrue,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '2.0.22+410001',
          releaseVersion: '2.0.22',
          channel: AppUpdateChannel.beta,
        ),
        isFalse,
      );
    });

    test('rejects a release from the wrong repository version family', () {
      expect(
        shouldOfferAppRelease(
          currentVersion: '1.0.1+410001',
          releaseVersion: '2.0.5',
          channel: AppUpdateChannel.public,
        ),
        isFalse,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '2.0.4+410001',
          releaseVersion: '1.0.2',
          channel: AppUpdateChannel.beta,
        ),
        isFalse,
      );
    });

    test('legacy 1.x builds cross the Public version reset only once', () {
      expect(
        shouldOfferAppRelease(
          currentVersion: '1.11.33+400001',
          releaseVersion: '1.0.2',
          channel: AppUpdateChannel.public,
        ),
        isTrue,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '1.11.33+410001',
          releaseVersion: '1.0.2',
          channel: AppUpdateChannel.public,
        ),
        isFalse,
      );
      expect(
        shouldOfferAppRelease(
          currentVersion: '1.11.33',
          releaseVersion: '1.0.2',
          channel: AppUpdateChannel.public,
        ),
        isFalse,
      );
    });

    test('prefers a universal APK on every supported device ABI', () {
      const assets = [
        AppReleaseAsset(
          name: 'TetoTV-arm64-v8a.apk',
          apiUrl: 'arm64',
          publicUrl: 'arm64',
          size: 1,
        ),
        AppReleaseAsset(
          name: 'TetoTV-universal.apk',
          apiUrl: 'universal',
          publicUrl: 'universal',
          size: 1,
        ),
        AppReleaseAsset(
          name: 'TetoTV-fire-tv-32bit.apk',
          apiUrl: 'arm32',
          publicUrl: 'arm32',
          size: 1,
        ),
      ];
      for (final abis in [
        const ['arm64-v8a'],
        const ['armeabi-v7a'],
        const ['x86_64'],
        const <String>[],
      ]) {
        expect(selectApkAsset(assets, abis).apiUrl, 'universal');
      }
    });

    test('APK inspection retains package and version compatibility data', () {
      final inspection = ApkCompatibilityInfo.fromMap(const {
        'compatible': false,
        'issues': <String>['Target build is lower.'],
        'issueCodes': <String>['version_downgrade'],
        'packageName': 'dev.animetv.anime_tv',
        'versionCode': 410001,
        'versionName': '1.0.2',
        'installedVersionCode': 410008,
        'installedVersionName': '2.0.31',
      });
      expect(inspection.packageName, 'dev.animetv.anime_tv');
      expect(inspection.versionName, '1.0.2');
      expect(inspection.issueCodes, ['version_downgrade']);
      expect(inspection.installedVersionCode, 410008);
      expect(inspection.installedVersionName, '2.0.31');
      expect(inspection.compatible, isFalse);
    });
  });

  group('anonymous GitHub release source', () {
    test('Public checks the exact public latest endpoint anonymously', () async {
      RequestOptions? request;
      final dio = _metadataDio((options) {
        request = options;
        return _githubRelease(
          '1.0.2',
          repository: tetoTvPublicReleaseRepository,
        );
      });

      final release = await GitHubAppReleaseSource(
        dio,
        repository: tetoTvPublicReleaseRepository,
        releaseMajor: 1,
        channelName: 'Public',
      ).latest(deviceAbis: const ['arm64-v8a']);

      expect(
        request?.uri.toString(),
        'https://api.github.com/repos/LindersOSX/TetoTV-Public/releases/latest',
      );
      expect(_authorization(request), isNull);
      expect(release.version, '1.0.2');
      expect(release.notes, 'Notes for 1.0.2');
      expect(release.releasedAtUtc, DateTime.utc(2026, 8, 16, 19, 24, 30));
      expect(release.asset.name, 'TetoTV-v1.0.2-universal.apk');
      expect(
        release.asset.publicUrl,
        'https://github.com/LindersOSX/TetoTV-Public/releases/download/'
        'v1.0.2/TetoTV-v1.0.2-universal.apk',
      );
    });

    test('release notes expose a validated Android build code', () async {
      final release = await GitHubAppReleaseSource(
        _metadataDio(
          (_) => _githubRelease(
            '1.0.5',
            repository: tetoTvPublicReleaseRepository,
            body:
                'Signed Public counterpart with Android build code `410008`.\n'
                '<!-- tetotv-android-version-code: 410008 -->',
          ),
        ),
      ).latest(deviceAbis: const []);

      expect(release.androidVersionCode, 410008);
    });

    test('conflicting Android build metadata is rejected', () async {
      await expectLater(
        GitHubAppReleaseSource(
          _metadataDio(
            (_) => _githubRelease(
              '1.0.5',
              repository: tetoTvPublicReleaseRepository,
              body:
                  'Android build code `410008`.\n'
                  '<!-- tetotv-android-version-code: 410009 -->',
            ),
          ),
        ).latest(deviceAbis: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('Beta checks the exact beta latest endpoint anonymously', () async {
      RequestOptions? request;
      final dio = _metadataDio((options) {
        request = options;
        return _githubRelease(
          '2.0.5',
          repository: tetoTvBetaReleaseRepository,
          prerelease: false,
        );
      });

      final release = await GitHubAppReleaseSource(
        dio,
        repository: tetoTvBetaReleaseRepository,
        releaseMajor: 2,
        channelName: 'Beta',
        allowPrerelease: true,
      ).latest(deviceAbis: const ['armeabi-v7a']);

      expect(
        request?.uri.toString(),
        'https://api.github.com/repos/LindersOSX/TetoTV-Beta/releases/latest',
      );
      expect(_authorization(request), isNull);
      expect(release.version, '2.0.5');
      expect(release.releasedAtUtc, DateTime.utc(2026, 8, 16, 19, 24, 30));
      expect(release.asset.name, endsWith('-universal.apk'));
    });

    test('Beta accepts the descriptive universal APK release name', () async {
      const assetName =
          'TetoTV-v2.0.28-AndroidTV-FireTV-ARM32-ARM64-universal.apk';
      final payload =
          _githubRelease(
              '2.0.28',
              repository: tetoTvBetaReleaseRepository,
              prerelease: false,
            )
            ..['assets'] = [
              _githubAsset(
                version: '2.0.28',
                repository: tetoTvBetaReleaseRepository,
                name: assetName,
                id: 28,
              ),
            ];

      final release = await GitHubAppReleaseSource(
        _metadataDio((_) => payload),
        repository: tetoTvBetaReleaseRepository,
        releaseMajor: 2,
        channelName: 'Beta',
        allowPrerelease: true,
      ).latest(deviceAbis: const ['arm64-v8a']);

      expect(release.asset.name, assetName);
      expect(
        release.asset.publicUrl,
        'https://github.com/LindersOSX/TetoTV-Beta/releases/download/'
        'v2.0.28/$assetName',
      );
    });

    test('release date prefers published_at and safely falls back', () async {
      final published = await GitHubAppReleaseSource(
        _metadataDio(
          (_) => _githubRelease(
            '1.0.2',
            repository: tetoTvPublicReleaseRepository,
            publishedAt: '2026-08-16T14:24:30-05:00',
            createdAt: '2026-08-14T01:02:03Z',
          ),
        ),
      ).latest(deviceAbis: const []);
      expect(published.releasedAtUtc, DateTime.utc(2026, 8, 16, 19, 24, 30));

      final created = await GitHubAppReleaseSource(
        _metadataDio(
          (_) => _githubRelease(
            '1.0.2',
            repository: tetoTvPublicReleaseRepository,
            publishedAt: 'not-a-date',
            createdAt: '2026-08-14T01:02:03Z',
          ),
        ),
      ).latest(deviceAbis: const []);
      expect(created.releasedAtUtc, DateTime.utc(2026, 8, 14, 1, 2, 3));

      final missing = await GitHubAppReleaseSource(
        _metadataDio(
          (_) => _githubRelease(
            '1.0.2',
            repository: tetoTvPublicReleaseRepository,
            publishedAt: null,
            createdAt: 'invalid',
          ),
        ),
      ).latest(deviceAbis: const []);
      expect(missing.releasedAtUtc, isNull);
    });

    test('Public and Beta version labels include a clear release date', () {
      final publicRelease = AppReleaseInfo(
        tagName: 'v1.0.2',
        version: '1.0.2',
        name: 'TetoTV 1.0.2',
        asset: _directRelease.asset,
        releasedAtUtc: DateTime.utc(2026, 8, 16, 23, 59),
      );
      final betaRelease = AppReleaseInfo(
        tagName: 'v2.0.10',
        version: '2.0.10',
        name: 'TetoTV 2.0.10',
        asset: _directRelease.asset,
        releasedAtUtc: DateTime.utc(2026, 8, 16, 23, 59),
      );

      expect(
        appReleaseDisplayLabel(publicRelease, AppUpdateChannel.public),
        '1.0.2 • Aug 16, 2026',
      );
      expect(
        appReleaseDisplayLabel(betaRelease, AppUpdateChannel.beta),
        '2.0.10 Beta • Aug 16, 2026',
      );
      expect(formatAppReleaseDate(null), isNull);
    });

    test('Beta does not require the GitHub prerelease flag', () async {
      for (final prerelease in [false, true]) {
        final dio = _metadataDio(
          (_) => _githubRelease(
            '2.0.5',
            repository: tetoTvBetaReleaseRepository,
            prerelease: prerelease,
          ),
        );
        final release = await GitHubAppReleaseSource(
          dio,
          repository: tetoTvBetaReleaseRepository,
          releaseMajor: 2,
          channelName: 'Beta',
          allowPrerelease: true,
        ).latest(deviceAbis: const []);
        expect(release.version, '2.0.5');
      }
    });

    test(
      'Public rejects draft, prerelease, and non-1.x latest metadata',
      () async {
        for (final payload in [
          _githubRelease(
            '1.0.2',
            repository: tetoTvPublicReleaseRepository,
            draft: true,
          ),
          _githubRelease(
            '1.0.2',
            repository: tetoTvPublicReleaseRepository,
            prerelease: true,
          ),
          _githubRelease('2.0.5', repository: tetoTvPublicReleaseRepository),
        ]) {
          await expectLater(
            GitHubAppReleaseSource(
              _metadataDio((_) => payload),
            ).latest(deviceAbis: const []),
            throwsA(isA<FormatException>()),
          );
        }
      },
    );

    test(
      'Public history uses GitHub directly and filters to completed 1.x',
      () async {
        RequestOptions? request;
        final dio = _listMetadataDio((options) {
          request = options;
          return [
            _githubRelease('1.0.2', repository: tetoTvPublicReleaseRepository),
            _githubRelease(
              '1.0.1',
              repository: tetoTvPublicReleaseRepository,
              prerelease: true,
            ),
            _githubRelease('1.0.1', repository: tetoTvPublicReleaseRepository),
            _githubRelease('2.0.5', repository: tetoTvPublicReleaseRepository),
            _githubRelease(
              '1.0.0',
              repository: tetoTvPublicReleaseRepository,
              draft: true,
            ),
          ];
        });

        final releases = await GitHubAppReleaseSource(
          dio,
        ).history(deviceAbis: const ['arm64-v8a']);

        expect(request?.uri.path, '/repos/LindersOSX/TetoTV-Public/releases');
        expect(request?.uri.queryParameters['per_page'], '20');
        expect(_authorization(request), isNull);
        expect(releases.map((item) => item.version), ['1.0.2', '1.0.1']);
        expect(
          releases.map((item) => item.releasedAtUtc),
          everyElement(DateTime.utc(2026, 8, 16, 19, 24, 30)),
        );
      },
    );

    test(
      'Beta history is repository-scoped and accepts either release flag',
      () async {
        RequestOptions? request;
        final dio = _listMetadataDio((options) {
          request = options;
          return [
            _githubRelease(
              '2.0.5',
              repository: tetoTvBetaReleaseRepository,
              prerelease: false,
            ),
            _githubRelease(
              '2.0.4',
              repository: tetoTvBetaReleaseRepository,
              prerelease: true,
            ),
            _githubRelease('1.0.2', repository: tetoTvBetaReleaseRepository),
          ];
        });

        final releases = await GitHubAppReleaseSource(
          dio,
          repository: tetoTvBetaReleaseRepository,
          releaseMajor: 2,
          channelName: 'Beta',
          allowPrerelease: true,
        ).history(deviceAbis: const ['armeabi-v7a']);

        expect(request?.uri.path, '/repos/LindersOSX/TetoTV-Beta/releases');
        expect(_authorization(request), isNull);
        expect(releases.map((item) => item.version), ['2.0.5', '2.0.4']);
        expect(
          releases.map((item) => item.releasedAtUtc),
          everyElement(DateTime.utc(2026, 8, 16, 19, 24, 30)),
        );
      },
    );

    test(
      'history rejects duplicate or non-descending release versions',
      () async {
        for (final versions in [
          const ['1.0.1', '1.0.2'],
          const ['1.0.2', '1.0.2'],
        ]) {
          final dio = _listMetadataDio(
            (_) => versions
                .map(
                  (version) => _githubRelease(
                    version,
                    repository: tetoTvPublicReleaseRepository,
                  ),
                )
                .toList(),
          );
          await expectLater(
            GitHubAppReleaseSource(dio).history(deviceAbis: const []),
            throwsA(isA<FormatException>()),
          );
        }
      },
    );

    test('prefers the canonical release-named universal asset', () async {
      final exact = _githubAsset(
        version: '1.0.2',
        repository: tetoTvPublicReleaseRepository,
        name: 'TetoTV-v1.0.2-universal.apk',
        id: 2,
      );
      final payload =
          _githubRelease('1.0.2', repository: tetoTvPublicReleaseRepository)
            ..['assets'] = [
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'community-universal.apk',
                id: 1,
              ),
              exact,
            ];

      final release = await GitHubAppReleaseSource(
        _metadataDio((_) => payload),
      ).latest(deviceAbis: const []);

      expect(release.asset.name, exact['name']);
      expect(release.asset.apiUrl, exact['url']);
    });

    test('prefers a universal asset over ABI-specific APKs', () async {
      final universal = _githubAsset(
        version: '1.0.2',
        repository: tetoTvPublicReleaseRepository,
        name: 'community-universal.apk',
        id: 3,
      );
      final payload =
          _githubRelease('1.0.2', repository: tetoTvPublicReleaseRepository)
            ..['assets'] = [
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'TetoTV-v1.0.2-arm64-v8a.apk',
                id: 1,
              ),
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'TetoTV-v1.0.2-armeabi-v7a.apk',
                id: 2,
              ),
              universal,
            ];

      final release = await GitHubAppReleaseSource(
        _metadataDio((_) => payload),
      ).latest(deviceAbis: const ['arm64-v8a']);

      expect(release.asset.name, universal['name']);
    });

    test('falls back to the uniquely matching device APK', () async {
      final payload =
          _githubRelease('1.0.2', repository: tetoTvPublicReleaseRepository)
            ..['assets'] = [
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'TetoTV-v1.0.2-arm64-v8a.apk',
                id: 1,
              ),
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'TetoTV-v1.0.2-fire-tv-32bit.apk',
                id: 2,
              ),
            ];

      final arm64 = await GitHubAppReleaseSource(
        _metadataDio((_) => payload),
      ).latest(deviceAbis: const ['arm64-v8a']);
      final arm32 = await GitHubAppReleaseSource(
        _metadataDio((_) => payload),
      ).latest(deviceAbis: const ['armeabi-v7a']);

      expect(arm64.asset.name, 'TetoTV-v1.0.2-arm64-v8a.apk');
      expect(arm32.asset.name, 'TetoTV-v1.0.2-fire-tv-32bit.apk');
    });

    test('rejects ambiguous ABI-specific fallback assets', () async {
      final payload =
          _githubRelease('1.0.2', repository: tetoTvPublicReleaseRepository)
            ..['assets'] = [
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'TetoTV-v1.0.2-arm64-v8a.apk',
                id: 1,
              ),
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'TetoTV-v1.0.2-arm64.apk',
                id: 2,
              ),
            ];

      await expectLater(
        GitHubAppReleaseSource(
          _metadataDio((_) => payload),
        ).latest(deviceAbis: const ['arm64-v8a']),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'a deceptive universal substring cannot override the ABI match',
      () async {
        final payload =
            _githubRelease('1.0.2', repository: tetoTvPublicReleaseRepository)
              ..['assets'] = [
                _githubAsset(
                  version: '1.0.2',
                  repository: tetoTvPublicReleaseRepository,
                  name: 'TetoTV-v1.0.2-universal-armeabi-v7a.apk',
                  id: 1,
                ),
                _githubAsset(
                  version: '1.0.2',
                  repository: tetoTvPublicReleaseRepository,
                  name: 'TetoTV-v1.0.2-arm64-v8a.apk',
                  id: 2,
                ),
              ];

        final release = await GitHubAppReleaseSource(
          _metadataDio((_) => payload),
        ).latest(deviceAbis: const ['arm64-v8a']);

        expect(release.asset.name, 'TetoTV-v1.0.2-arm64-v8a.apk');
      },
    );

    test('rejects ambiguous fallback universal assets', () async {
      final payload =
          _githubRelease('1.0.2', repository: tetoTvPublicReleaseRepository)
            ..['assets'] = [
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'first-universal.apk',
                id: 1,
              ),
              _githubAsset(
                version: '1.0.2',
                repository: tetoTvPublicReleaseRepository,
                name: 'second-universal.apk',
                id: 2,
              ),
            ];
      await expectLater(
        GitHubAppReleaseSource(
          _metadataDio((_) => payload),
        ).latest(deviceAbis: const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects off-repository, mutable, and non-HTTPS asset URLs', () async {
      final valid = _githubRelease(
        '1.0.2',
        repository: tetoTvPublicReleaseRepository,
      );
      final original =
          (valid['assets']! as List).single as Map<String, dynamic>;
      for (final badUrl in [
        'https://example.com/TetoTV-v1.0.2-universal.apk',
        'http://github.com/LindersOSX/TetoTV-Public/releases/download/'
            'v1.0.2/TetoTV-v1.0.2-universal.apk',
        'https://github.com/LindersOSX/TetoTV-Public/releases/latest/download/'
            'TetoTV-v1.0.2-universal.apk',
        'https://github.com/LindersOSX/TetoTV-Public/releases/download/'
            'v1.0.2/TetoTV-v1.0.2-universal.apk?token=leak',
        'https://user@github.com/LindersOSX/TetoTV-Public/releases/download/'
            'v1.0.2/TetoTV-v1.0.2-universal.apk',
      ]) {
        final payload = <String, dynamic>{
          ...valid,
          'assets': [
            <String, dynamic>{...original, 'browser_download_url': badUrl},
          ],
        };
        await expectLater(
          GitHubAppReleaseSource(
            _metadataDio((_) => payload),
          ).latest(deviceAbis: const []),
          throwsA(isA<FormatException>()),
          reason: badUrl,
        );
      }
    });

    test('rejects malformed content type, size, name, and digest', () async {
      final base = _githubRelease(
        '1.0.2',
        repository: tetoTvPublicReleaseRepository,
      );
      final asset = (base['assets']! as List).single as Map<String, dynamic>;
      final mutations = <Map<String, dynamic>>[
        {...asset, 'content_type': 'text/html'},
        {...asset, 'size': 100},
        {...asset, 'name': '../TetoTV-v1.0.2-universal.apk'},
        {...asset, 'digest': 'sha256:not-a-digest'},
      ];
      for (final mutation in mutations) {
        final payload = <String, dynamic>{
          ...base,
          'assets': [mutation],
        };
        await expectLater(
          GitHubAppReleaseSource(
            _metadataDio((_) => payload),
          ).latest(deviceAbis: const []),
          throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
        );
      }
    });

    test(
      'downloads browser_download_url directly and reports progress',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'github-download-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final adapter = _DownloadAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        final destination =
            '${directory.path}${Platform.pathSeparator}update.apk';
        final progress = <(int, int)>[];

        await GitHubAppReleaseSource(dio).download(
          release: _directRelease,
          destination: destination,
          onProgress: (received, total) => progress.add((received, total)),
        );

        expect(adapter.uris.single, Uri.parse(_directRelease.asset.publicUrl));
        expect(adapter.authorizations, everyElement(isNull));
        expect(adapter.followRedirects, everyElement(isFalse));
        expect(await File(destination).readAsBytes(), adapter.payload);
        expect(progress, isNotEmpty);
      },
    );

    test('follows only trusted GitHub asset redirects anonymously', () async {
      final directory = await Directory.systemTemp.createTemp(
        'github-redirect-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final adapter = _DownloadAdapter(
        redirectLocation:
            'https://release-assets.githubusercontent.com/github-production-'
            'release-asset/123/update.apk?sp=r&sig=signed',
      );
      final destination =
          '${directory.path}${Platform.pathSeparator}update.apk';
      await GitHubAppReleaseSource(Dio()..httpClientAdapter = adapter).download(
        release: _directRelease,
        destination: destination,
        onProgress: (_, _) {},
      );

      expect(adapter.uris, hasLength(2));
      expect(adapter.uris.last.host, 'release-assets.githubusercontent.com');
      expect(adapter.authorizations, everyElement(isNull));
      expect(adapter.followRedirects, everyElement(isFalse));
    });

    test('rejects an untrusted redirect and removes partial output', () async {
      final directory = await Directory.systemTemp.createTemp(
        'github-bad-redirect-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final adapter = _DownloadAdapter(
        redirectLocation: 'https://downloads.example/update.apk',
      );
      final destination =
          '${directory.path}${Platform.pathSeparator}update.apk';

      await expectLater(
        GitHubAppReleaseSource(Dio()..httpClientAdapter = adapter).download(
          release: _directRelease,
          destination: destination,
          onProgress: (_, _) {},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(File(destination).existsSync(), isFalse);
      expect(adapter.uris, hasLength(1));
    });

    test('revalidates release identity before any APK request', () async {
      final adapter = _DownloadAdapter();
      final forged = AppReleaseInfo(
        tagName: _directRelease.tagName,
        version: _directRelease.version,
        name: _directRelease.name,
        asset: AppReleaseAsset(
          name: _directRelease.asset.name,
          apiUrl: _directRelease.asset.apiUrl,
          publicUrl: 'https://example.com/update.apk',
          size: _directRelease.asset.size,
        ),
      );
      expect(
        () => GitHubAppReleaseSource(Dio()..httpClientAdapter = adapter).download(
          release: forged,
          destination:
              '${Directory.systemTemp.path}${Platform.pathSeparator}forged.apk',
          onProgress: (_, _) {},
        ),
        throwsFormatException,
      );
      expect(adapter.uris, isEmpty);
    });
  });

  group('update controller behavior', () {
    test('coalesces concurrent storage loads', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final version = Completer<String>();
      var loads = 0;
      final controller = _controller(
        storage: storage,
        publicSource: _MemoryReleaseSource('1.0.2'),
        currentVersion: () {
          loads++;
          return version.future;
        },
      );
      final first = controller.load();
      final second = controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(loads, 1);
      version.complete('1.0.1+410000');
      await Future.wait([first, second]);
      expect(controller.state.currentVersion, '1.0.1+410000');
    });

    test(
      'defaults a Public install to Public and persists Beta selection without Developer Mode',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'github_update_token': 'legacy-token',
          'beta_update_access_key': 'legacy-beta-key',
        });
        final public = _MemoryReleaseSource('1.0.2');
        final beta = _MemoryReleaseSource('2.0.5');
        final controller = _controller(
          storage: storage,
          publicSource: public,
          betaSource: beta,
        );

        await controller.load();
        expect(controller.state.updateChannel, AppUpdateChannel.public);
        await controller.setUpdateChannel(AppUpdateChannel.beta);
        expect(controller.state.updateChannel, AppUpdateChannel.beta);
        expect(await storage.read(key: updateChannelStorageKey), 'beta');
        expect(await storage.read(key: 'github_update_token'), isNull);
        expect(await storage.read(key: 'beta_update_access_key'), isNull);

        final restored = _controller(
          storage: storage,
          publicSource: public,
          betaSource: beta,
        );
        await restored.load();
        expect(restored.state.developerMode, isFalse);
        expect(restored.state.updateChannel, AppUpdateChannel.beta);
      },
    );

    test(
      'fresh 2.0.28 install checks Beta 2.0.29 instead of Public 1.0.4',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'beta-channel-inference-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final public = _MemoryReleaseSource('1.0.4');
        final beta = _MemoryReleaseSource('2.0.29');
        final controller = _controller(
          storage: storage,
          publicSource: public,
          betaSource: beta,
          cache: directory,
          currentVersion: () async => '2.0.28+410005',
        );

        await controller.checkForUpdates();

        expect(controller.state.updateChannel, AppUpdateChannel.beta);
        expect(public.latestCalls, 0);
        expect(public.downloadCalls, 0);
        expect(beta.latestCalls, 1);
        expect(beta.downloadCalls, 1);
        expect(controller.state.latestVersion, '2.0.29');
        expect(controller.state.phase, AppUpdatePhase.ready);
        expect(controller.state.message, contains('2.0.29 Beta'));
      },
    );

    test(
      'uses only the release source belonging to the selected channel',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          developerModeStorageKey: 'true',
          updateChannelStorageKey: AppUpdateChannel.beta.name,
        });
        final directory = await Directory.systemTemp.createTemp(
          'channel-source-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final public = _MemoryReleaseSource('1.0.2');
        final beta = _MemoryReleaseSource('2.0.5');
        final controller = _controller(
          storage: storage,
          publicSource: public,
          betaSource: beta,
          cache: directory,
          currentVersion: () async => '1.0.2+410001',
        );

        await controller.checkForUpdates();

        expect(public.latestCalls, 0);
        expect(public.downloadCalls, 0);
        expect(beta.latestCalls, 1);
        expect(beta.downloadCalls, 1);
        expect(controller.state.latestVersion, '2.0.5');
        expect(controller.state.phase, AppUpdatePhase.ready);
        expect(controller.state.message, contains('2.0.5 Beta'));
      },
    );

    test(
      'preserves download progress and opens the Android installer',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'controller-install-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final source = _MemoryReleaseSource('1.0.2');
        String? installedPath;
        final controller = _controller(
          storage: storage,
          publicSource: source,
          cache: directory,
          installer: (value) async {
            installedPath = value;
            return 'launched';
          },
        );

        await controller.checkForUpdates(launchInstaller: true);

        expect(source.progressEmitted, isTrue);
        expect(controller.state.progress, 1);
        expect(controller.state.phase, AppUpdatePhase.ready);
        expect(installedPath, controller.state.downloadedPath);
        expect(controller.state.message, contains('Android installer'));
      },
    );

    test(
      'installs an older release when it is an equal-build counterpart',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          developerModeStorageKey: 'true',
        });
        final directory = await Directory.systemTemp.createTemp(
          'history-install-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final source = _MemoryReleaseSource(
          '1.0.2',
          historyVersions: const ['1.0.2', '1.0.1'],
          androidVersionCodes: const {'1.0.2': 410001, '1.0.1': 410001},
        );
        var installs = 0;
        final controller = _controller(
          storage: storage,
          publicSource: source,
          cache: directory,
          currentVersion: () async => '1.0.2+410001',
          installer: (_) async {
            installs++;
            return 'launched';
          },
        );

        await controller.refreshReleaseHistory();
        expect(controller.state.releaseHistory.map((item) => item.version), [
          '1.0.2',
          '1.0.1',
        ]);
        await controller.installReleaseFromHistory(
          controller.state.releaseHistory.last,
        );

        expect(source.downloadedVersions, ['1.0.1']);
        expect(installs, 1);
        expect(controller.state.phase, AppUpdatePhase.ready);
      },
    );

    test(
      'does not download a history release with a known lower build code',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          developerModeStorageKey: 'true',
        });
        final source = _MemoryReleaseSource(
          '1.0.2',
          historyVersions: const ['1.0.2', '1.0.1'],
          androidVersionCodes: const {'1.0.2': 410008, '1.0.1': 410007},
        );
        var installs = 0;
        final controller = _controller(
          storage: storage,
          publicSource: source,
          currentVersion: () async => '1.0.2+410008',
          installer: (_) async {
            installs++;
            return 'launched';
          },
        );

        await controller.refreshReleaseHistory();
        await controller.installReleaseFromHistory(
          controller.state.releaseHistory.last,
        );

        expect(source.downloadCalls, 0);
        expect(installs, 0);
        expect(controller.state.phase, AppUpdatePhase.error);
        expect(controller.state.message, contains('target build 410007'));
        expect(controller.state.message, contains('installed build 410008'));
        expect(controller.state.message, contains('cannot bypass'));
      },
    );

    test(
      'does not download a known lower-build cross-channel release',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          updateChannelStorageKey: AppUpdateChannel.public.name,
        });
        final source = _MemoryReleaseSource(
          '1.0.4',
          androidVersionCodes: const {'1.0.4': 410001},
        );
        final controller = _controller(
          storage: storage,
          publicSource: source,
          currentVersion: () async => '2.0.31+410008',
        );

        await controller.checkForUpdates();

        expect(source.downloadCalls, 0);
        expect(controller.state.phase, AppUpdatePhase.error);
        expect(controller.state.latestVersion, '1.0.4');
        expect(controller.state.message, contains('target build 410001'));
        expect(controller.state.message, contains('installed build 410008'));
      },
    );

    test('refuses a forged release that was not loaded in history', () async {
      FlutterSecureStorage.setMockInitialValues({
        developerModeStorageKey: 'true',
      });
      final source = _MemoryReleaseSource('1.0.2');
      final controller = _controller(storage: storage, publicSource: source);
      await controller.refreshReleaseHistory();
      final valid = controller.state.releaseHistory.single;
      final forged = AppReleaseInfo(
        tagName: valid.tagName,
        version: valid.version,
        name: valid.name,
        asset: AppReleaseAsset(
          name: valid.asset.name,
          apiUrl: valid.asset.apiUrl,
          publicUrl: 'https://example.com/forged.apk',
          size: valid.asset.size,
        ),
      );
      await controller.installReleaseFromHistory(forged);
      expect(controller.state.phase, AppUpdatePhase.error);
      expect(source.downloadCalls, 0);
    });

    test('deletes an APK rejected by compatibility inspection', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('bad-compat-');
      addTearDown(() => directory.delete(recursive: true));
      final source = _MemoryReleaseSource('1.0.2');
      final controller = _controller(
        storage: storage,
        publicSource: source,
        cache: directory,
        inspector: (_) async => const ApkCompatibilityInfo(
          compatible: false,
          issues: ['Unsupported ABI.'],
          packageName: 'dev.animetv.anime_tv',
          versionCode: 410001,
          versionName: '1.0.2',
        ),
      );

      await controller.checkForUpdates();

      expect(controller.state.phase, AppUpdatePhase.error);
      expect(controller.state.message, contains('not compatible'));
      expect(
        File(
          '${directory.path}${Platform.pathSeparator}updates${Platform.pathSeparator}TetoTV-v1.0.2-universal.apk',
        ).existsSync(),
        isFalse,
      );
    });

    test(
      'shows structured Android downgrade details after APK inspection',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'inspected-downgrade-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final source = _MemoryReleaseSource('1.0.2');
        final controller = _controller(
          storage: storage,
          publicSource: source,
          cache: directory,
          inspector: (_) async => const ApkCompatibilityInfo(
            compatible: false,
            issues: ['Target build is lower.'],
            issueCodes: ['version_downgrade'],
            packageName: 'dev.animetv.anime_tv',
            versionCode: 410007,
            versionName: '1.0.2',
            installedVersionCode: 410008,
            installedVersionName: '2.0.31',
            signerMatches: true,
          ),
        );

        await controller.checkForUpdates();

        expect(source.downloadCalls, 1);
        expect(controller.state.phase, AppUpdatePhase.error);
        expect(controller.state.message, contains('target build 410007'));
        expect(controller.state.message, contains('installed build 410008'));
        expect(controller.state.message, contains('cannot bypass'));
        expect(
          File(
            '${directory.path}${Platform.pathSeparator}updates${Platform.pathSeparator}TetoTV-v1.0.2-universal.apk',
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'deletes an APK whose inspected version does not match the release',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'wrong-version-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final controller = _controller(
          storage: storage,
          publicSource: _MemoryReleaseSource('1.0.2'),
          cache: directory,
          inspector: (_) async => const ApkCompatibilityInfo(
            compatible: true,
            issues: [],
            packageName: 'dev.animetv.anime_tv',
            versionCode: 410001,
            versionName: '9.9.9',
          ),
        );
        await controller.checkForUpdates();
        expect(controller.state.phase, AppUpdatePhase.error);
        expect(controller.state.message, contains('selected release version'));
      },
    );

    test(
      'deletes an APK that fails the optional GitHub SHA-256 digest',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp('bad-digest-');
        addTearDown(() => directory.delete(recursive: true));
        final source = _MemoryReleaseSource(
          '1.0.2',
          digest: List.filled(64, '0').join(),
        );
        final controller = _controller(
          storage: storage,
          publicSource: source,
          cache: directory,
        );
        await controller.checkForUpdates();
        expect(controller.state.phase, AppUpdatePhase.error);
        expect(controller.state.message, contains('integrity check'));
        final file = File(
          '${directory.path}${Platform.pathSeparator}updates${Platform.pathSeparator}'
          'TetoTV-v1.0.2-universal.apk',
        );
        expect(file.existsSync(), isFalse);
      },
    );

    test('accepts a matching SHA-256 digest', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('good-digest-');
      addTearDown(() => directory.delete(recursive: true));
      final digest = sha256.convert(_MemoryReleaseSource.payload).toString();
      final controller = _controller(
        storage: storage,
        publicSource: _MemoryReleaseSource('1.0.2', digest: digest),
        cache: directory,
      );
      await controller.checkForUpdates();
      expect(controller.state.phase, AppUpdatePhase.ready);
    });

    test(
      'shows release notes only after the target version is installed',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'release-notes-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final source = _MemoryReleaseSource('1.0.2', notes: 'Public notes');
        final downloading = _controller(
          storage: storage,
          publicSource: source,
          cache: directory,
        );
        await downloading.checkForUpdates();
        expect(await downloading.takeInstalledReleaseNotes(), isNull);

        final installed = _controller(
          storage: storage,
          publicSource: source,
          currentVersion: () async => '1.0.2+410001',
        );
        expect(await installed.takeInstalledReleaseNotes(), 'Public notes');
        expect(await installed.takeInstalledReleaseNotes(), isNull);
      },
    );

    test('automatic checks preserve throttling and do not install', () async {
      final now = DateTime.now().toUtc();
      FlutterSecureStorage.setMockInitialValues({
        lastAutomaticUpdateCheckStorageKey: now.toIso8601String(),
      });
      final source = _MemoryReleaseSource('1.0.2');
      var installs = 0;
      final controller = _controller(
        storage: storage,
        publicSource: source,
        installer: (_) async {
          installs++;
          return 'launched';
        },
      );
      await controller.checkForUpdates(automatic: true);
      expect(source.latestCalls, 0);
      expect(installs, 0);
    });

    test('future automatic-check timestamps do not suppress retries', () async {
      FlutterSecureStorage.setMockInitialValues({
        lastAutomaticUpdateCheckStorageKey: DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String(),
      });
      final source = _MemoryReleaseSource('1.0.1');
      final controller = _controller(
        storage: storage,
        publicSource: source,
        currentVersion: () async => '1.0.1+410001',
      );
      await controller.checkForUpdates(automatic: true);
      expect(source.latestCalls, 1);
      expect(controller.state.phase, AppUpdatePhase.upToDate);
    });
  });
}

String? _authorization(RequestOptions? request) {
  if (request == null) return null;
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == HttpHeaders.authorizationHeader) {
      return entry.value?.toString();
    }
  }
  return null;
}

Dio _metadataDio(
  Map<String, dynamic> Function(RequestOptions options) response,
) => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: HttpStatus.ok,
          data: response(options),
        ),
      ),
    ),
  );

Dio _listMetadataDio(
  List<Map<String, dynamic>> Function(RequestOptions options) response,
) => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<List<dynamic>>(
          requestOptions: options,
          statusCode: HttpStatus.ok,
          data: response(options),
        ),
      ),
    ),
  );

Map<String, dynamic> _githubRelease(
  String version, {
  required String repository,
  bool draft = false,
  bool prerelease = false,
  String? publishedAt = '2026-08-16T19:24:30Z',
  String? createdAt,
  String? body,
}) => <String, dynamic>{
  'tag_name': 'v$version',
  'name': 'TetoTV $version',
  'body': body ?? 'Notes for $version',
  'draft': draft,
  'prerelease': prerelease,
  'published_at': ?publishedAt,
  'created_at': ?createdAt,
  'assets': [
    _githubAsset(
      version: version,
      repository: repository,
      name: 'TetoTV-v$version-universal.apk',
      id: 1,
    ),
  ],
};

Map<String, dynamic> _githubAsset({
  required String version,
  required String repository,
  required String name,
  required int id,
}) => <String, dynamic>{
  'name': name,
  'url': 'https://api.github.com/repos/$repository/releases/assets/$id',
  'browser_download_url':
      'https://github.com/$repository/releases/download/v$version/$name',
  'size': 2 * 1024 * 1024,
  'content_type': 'application/vnd.android.package-archive',
};

const _directRelease = AppReleaseInfo(
  tagName: 'v1.0.2',
  version: '1.0.2',
  name: 'TetoTV 1.0.2',
  asset: AppReleaseAsset(
    name: 'TetoTV-v1.0.2-universal.apk',
    apiUrl:
        'https://api.github.com/repos/LindersOSX/TetoTV-Public/releases/assets/1',
    publicUrl:
        'https://github.com/LindersOSX/TetoTV-Public/releases/download/'
        'v1.0.2/TetoTV-v1.0.2-universal.apk',
    size: 4,
  ),
);

class _DownloadAdapter implements HttpClientAdapter {
  _DownloadAdapter({this.redirectLocation});

  final String? redirectLocation;
  final payload = const [1, 2, 3, 4];
  final uris = <Uri>[];
  final authorizations = <String?>[];
  final followRedirects = <bool>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri);
    authorizations.add(_authorization(options));
    followRedirects.add(options.followRedirects);
    if (redirectLocation != null && uris.length == 1) {
      return ResponseBody.fromBytes(
        const [],
        HttpStatus.found,
        headers: {
          HttpHeaders.locationHeader: [redirectLocation!],
          Headers.contentLengthHeader: ['0'],
        },
      );
    }
    return ResponseBody.fromBytes(
      payload,
      HttpStatus.ok,
      headers: {
        Headers.contentLengthHeader: [payload.length.toString()],
        Headers.contentTypeHeader: ['application/vnd.android.package-archive'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MemoryReleaseSource implements AppReleaseSource {
  _MemoryReleaseSource(
    this.version, {
    this.historyVersions,
    this.androidVersionCodes = const {},
    this.digest,
    this.notes = '',
  });

  static final List<int> payload = List<int>.filled(1024 * 1024, 7);

  final String version;
  final List<String>? historyVersions;
  final Map<String, int> androidVersionCodes;
  final String? digest;
  final String notes;
  int latestCalls = 0;
  int downloadCalls = 0;
  bool progressEmitted = false;
  final downloadedVersions = <String>[];

  AppReleaseInfo _release(String value) => AppReleaseInfo(
    tagName: 'v$value',
    version: value,
    name: 'TetoTV $value',
    notes: notes,
    androidVersionCode: androidVersionCodes[value],
    asset: AppReleaseAsset(
      name: 'TetoTV-v$value-universal.apk',
      apiUrl: 'https://api.github.com/assets/$value',
      publicUrl: 'https://example.com/TetoTV-v$value-universal.apk',
      size: payload.length,
      sha256Digest: digest,
    ),
  );

  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) async {
    latestCalls++;
    return _release(version);
  }

  @override
  Future<List<AppReleaseInfo>> history({
    required List<String> deviceAbis,
  }) async {
    return (historyVersions ?? [version]).map(_release).toList(growable: false);
  }

  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) async {
    downloadCalls++;
    downloadedVersions.add(release.version);
    await File(destination).writeAsBytes(payload, flush: true);
    onProgress(payload.length ~/ 2, payload.length);
    onProgress(payload.length, payload.length);
    progressEmitted = true;
  }
}

AppUpdateController _controller({
  required FlutterSecureStorage storage,
  required AppReleaseSource publicSource,
  AppReleaseSource? betaSource,
  Future<String> Function()? currentVersion,
  Directory? cache,
  Future<String> Function(String path)? installer,
  Future<ApkCompatibilityInfo> Function(String path)? inspector,
}) => AppUpdateController(
  storage,
  publicSource,
  currentVersion ?? () async => '1.0.1+410000',
  () async => const ['arm64-v8a', 'armeabi-v7a'],
  () async => cache ?? Directory.systemTemp,
  installer ?? (_) async => 'launched',
  betaReleaseSource: betaSource,
  apkInspector: inspector,
);
