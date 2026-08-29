import 'dart:convert';

import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PhoneSetupBundle strict parsing', () {
    test(
      'accepts only the documented version-one bundle and deduplicates sources',
      () {
        final bundle = _parse({
          'version': 1,
          'preferences': {
            'preferred_audio': 'dub',
            'title_language': 'english',
            'built_in_keyboard': true,
            'auto_skip_intros': true,
            'auto_skip_outros': false,
            'home_layout': 'cinematic',
            'interface_mode': 'automatic',
            'show_hero': true,
            'show_poster_metadata': false,
            'show_my_list': true,
            'discover': true,
            'calendar': true,
            'watch_party': true,
            'downloads': false,
            'anonymous_crash': false,
            'anonymous_usage': true,
            'tracking_provider': 'anilist',
            'debrid_provider': 'realdebrid',
            'link_discord': true,
          },
          'sources': {
            'repository_urls': [
              'https://example.test/marketplace.json',
              'https://example.test/marketplace.json',
            ],
            'manifest_urls': ['https://example.test/manifest.json'],
          },
          'credentials': {
            'tracking_token': 'tracker-secret',
            'debrid_credential': 'debrid-secret',
          },
        });

        expect(bundle.preferences.choiceCount, 19);
        expect(bundle.preferences.preferredAudio, 'dub');
        expect(bundle.preferences.titleLanguage, 'english');
        expect(bundle.preferences.trackingProvider, 'anilist');
        expect(bundle.preferences.debridProvider, 'realdebrid');
        expect(bundle.preferences.linkDiscord, isTrue);
        expect(bundle.repositoryUrls, [
          'https://example.test/marketplace.json',
        ]);
        expect(bundle.manifestUrls, ['https://example.test/manifest.json']);
        expect(bundle.credentials.trackingToken, 'tracker-secret');
        expect(bundle.credentials.debridCredential, 'debrid-secret');
      },
    );

    test('accepts complete version-three linked account credentials', () {
      final bundle = _parse({
        'version': 3,
        'preferences': {
          'tracking_provider': 'myanimelist',
          'debrid_provider': 'realdebrid',
          'link_discord': true,
        },
        'sources': const <String, Object?>{},
        'credentials': {
          'tracking': {
            'provider': 'myanimelist',
            'access_token': 'mal-access-token',
            'refresh_token': 'mal-refresh-token',
            'token_type': 'Bearer',
            'expires_at': 2000000000,
          },
          'debrid': {
            'provider': 'realdebrid',
            'access_token': 'rd-access-token',
            'refresh_token': 'rd-refresh-token',
            'client_id': 'rd-client-id',
            'client_secret': 'rd-client-secret',
            'expires_at': 2000000000,
          },
          'discord': {
            'access_token': 'discord-access-token',
            'refresh_token': 'discord-refresh-token',
            'token_type': 1,
            'expires_at': 2000000000,
            'scopes': ['openid', 'sdk.social_layer_presence'],
            'minimum_age_confirmation': {'version': 1, 'confirmed': true},
          },
        },
      });

      expect(bundle.protocolVersion, 3);
      expect(bundle.credentials.tracking?.provider, 'myanimelist');
      expect(bundle.credentials.tracking?.refreshToken, 'mal-refresh-token');
      expect(bundle.credentials.tracking?.expiresAt, isNotNull);
      expect(bundle.credentials.debrid?.provider, 'realdebrid');
      expect(bundle.credentials.debrid?.clientSecret, 'rd-client-secret');
      expect(bundle.credentials.discord?.tokenType, 1);
      expect(bundle.credentials.discord?.scopes, [
        'openid',
        'sdk.social_layer_presence',
      ]);
      expect(
        bundle.credentials.discord?.minimumAgeConfirmation.confirmed,
        isTrue,
      );
    });

    test(
      'accepts the production AniList, Real-Debrid, and Discord bundle with empty sources',
      () {
        final bundle = _parse({
          'version': 3,
          'preferences': {
            'preferred_audio': 'sub',
            'title_language': 'english',
            'built_in_keyboard': true,
            'auto_skip_intros': false,
            'auto_skip_outros': false,
            'home_layout': 'cinematic',
            'interface_mode': 'automatic',
            'show_hero': true,
            'show_poster_metadata': true,
            'show_my_list': true,
            'discover': true,
            'calendar': true,
            'watch_party': true,
            'downloads': true,
            'anonymous_crash': false,
            'anonymous_usage': true,
            'link_discord': true,
            'tracking_provider': 'anilist',
            'debrid_provider': 'realdebrid',
          },
          'sources': {
            'repository_urls': <String>[],
            'manifest_urls': <String>[],
          },
          'credentials': {
            'tracking': {
              'provider': 'anilist',
              'access_token': 'anilist-access-token',
              'token_type': 'Bearer',
            },
            'debrid': {
              'provider': 'realdebrid',
              'access_token': 'rd-access-token',
              'refresh_token': 'rd-refresh-token',
              'client_id': 'rd-client-id',
              'client_secret': 'rd-client-secret',
              'expires_at': 2000000000,
            },
            'discord': {
              'access_token': 'discord-access-token',
              'refresh_token': 'discord-refresh-token',
              'token_type': 1,
              'expires_at': 2000000000,
              'scopes': ['openid', 'sdk.social_layer_presence'],
              'minimum_age_confirmation': {'version': 1, 'confirmed': true},
            },
          },
        });

        expect(bundle.protocolVersion, 3);
        expect(bundle.repositoryUrls, isEmpty);
        expect(bundle.manifestUrls, isEmpty);
        expect(bundle.credentials.tracking?.provider, 'anilist');
        expect(bundle.credentials.tracking?.refreshToken, isNull);
        expect(bundle.credentials.debrid?.provider, 'realdebrid');
        expect(bundle.credentials.debrid?.clientId, 'rd-client-id');
        expect(bundle.credentials.discord?.scopes, [
          'openid',
          'sdk.social_layer_presence',
        ]);
      },
    );

    test('accepts API-key debrid providers in version two', () {
      for (final provider in const ['torbox', 'alldebrid', 'premiumize']) {
        final bundle = _parse({
          'version': 2,
          'credentials': {
            'debrid': {'provider': provider, 'api_key': 'provider-api-key'},
          },
        });
        expect(bundle.credentials.debrid?.provider, provider);
        expect(bundle.credentials.debrid?.apiKey, 'provider-api-key');
      }
    });

    test('keeps version-two provider unions and nested keys strict', () {
      for (final payload in <Map<String, Object?>>[
        {
          'version': 2,
          'credentials': {
            'tracking': {
              'provider': 'anilist',
              'access_token': 'access-token',
              'refresh_token': 'not-supported',
            },
          },
        },
        {
          'version': 2,
          'credentials': {
            'tracking': {
              'provider': 'myanimelist',
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
            },
          },
        },
        {
          'version': 2,
          'credentials': {
            'debrid': {'provider': 'realdebrid', 'api_key': 'wrong-shape'},
          },
        },
        {
          'version': 2,
          'credentials': {
            'debrid': {
              'provider': 'torbox',
              'api_key': 'valid-api-key',
              'refresh_token': 'not-supported',
            },
          },
        },
        {
          'version': 3,
          'credentials': {
            'discord': {
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
              'token_type': 1,
              'expires_at': 2000000000,
              'scopes': ['openid'],
              'minimum_age_confirmation': {'version': 1, 'confirmed': true},
            },
          },
        },
        {
          'version': 3,
          'credentials': {
            'discord': {
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
              'token_type': 1,
              'expires_at': 2000000000,
              'scopes': ['openid', 'sdk.social_layer_presence'],
              'minimum_age_confirmation': {'version': 1, 'confirmed': true},
              'password': 'never-accepted',
            },
          },
        },
        {
          'version': 2,
          'preferences': {'tracking_provider': 'anilist'},
          'credentials': {
            'tracking': {
              'provider': 'myanimelist',
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
              'expires_at': 2000000000,
            },
          },
        },
      ]) {
        expect(() => _parse(payload), throwsFormatException);
      }
    });

    test('rejects legacy Discord imports without the version-three gate', () {
      expect(
        () => _parse({
          'version': 2,
          'credentials': {
            'discord': {
              'access_token': 'discord-access-token',
              'refresh_token': 'discord-refresh-token',
              'token_type': 1,
              'expires_at': 2000000000,
              'scopes': ['openid', 'sdk.social_layer_presence'],
            },
          },
        }),
        throwsFormatException,
      );
    });

    test('requires the exact accepted Discord confirmation object', () {
      for (final confirmation in <Object?>[
        null,
        {'version': 1, 'confirmed': false},
        {'version': 2, 'confirmed': true},
        {'version': 1, 'confirmed': true, 'age': 18},
      ]) {
        expect(
          () => _parse({
            'version': 3,
            'credentials': {
              'discord': {
                'access_token': 'discord-access-token',
                'refresh_token': 'discord-refresh-token',
                'token_type': 1,
                'expires_at': 2000000000,
                'scopes': ['openid', 'sdk.social_layer_presence'],
                'minimum_age_confirmation': ?confirmation,
              },
            },
          }),
          throwsFormatException,
        );
      }
    });

    for (final fixture in <({String name, Map<String, Object?> payload})>[
      (name: 'unknown root field', payload: {'version': 1, 'unexpected': true}),
      (
        name: 'unknown preference',
        payload: {
          'version': 1,
          'preferences': {'secret_debug_mode': true},
        },
      ),
      (
        name: 'unknown source field',
        payload: {
          'version': 1,
          'sources': {'file_paths': <String>[]},
        },
      ),
      (
        name: 'unknown credential field',
        payload: {
          'version': 1,
          'credentials': {'password': 'not-allowed'},
        },
      ),
      (
        name: 'unsupported audio choice',
        payload: {
          'version': 1,
          'preferences': {'preferred_audio': 'multi'},
        },
      ),
      (
        name: 'unsupported title language',
        payload: {
          'version': 1,
          'preferences': {'title_language': 'japanese'},
        },
      ),
      (
        name: 'non-boolean toggle',
        payload: {
          'version': 1,
          'preferences': {'downloads': 1},
        },
      ),
      (
        name: 'non-boolean Discord link choice',
        payload: {
          'version': 1,
          'preferences': {'link_discord': 'yes'},
        },
      ),
      (
        name: 'non-map section',
        payload: {'version': 1, 'preferences': <Object?>[]},
      ),
    ]) {
      test('rejects ${fixture.name}', () {
        expect(() => _parse(fixture.payload), throwsA(isA<FormatException>()));
      });
    }

    test('rejects malformed, empty, unsupported, and oversized cleartext', () {
      expect(() => PhoneSetupBundle.parse(const []), throwsFormatException);
      expect(
        () => PhoneSetupBundle.parse(const [0xff, 0xfe]),
        throwsFormatException,
      );
      expect(() => _parse({'version': 4}), throwsFormatException);
      expect(
        () => PhoneSetupBundle.parse(List<int>.filled(64 * 1024 + 1, 0x20)),
        throwsFormatException,
      );
    });

    test('enforces source item count, type, length, and non-empty values', () {
      expect(
        () => _parse({
          'version': 1,
          'sources': {
            'repository_urls': List.generate(
              9,
              (index) => 'https://example.test/$index.json',
            ),
          },
        }),
        throwsFormatException,
      );
      expect(
        () => _parse({
          'version': 1,
          'sources': {
            'manifest_urls': [7],
          },
        }),
        throwsFormatException,
      );
      expect(
        () => _parse({
          'version': 1,
          'sources': {
            'manifest_urls': [''],
          },
        }),
        throwsFormatException,
      );
      expect(
        () => _parse({
          'version': 1,
          'sources': {
            'repository_urls': ['x' * 2049],
          },
        }),
        throwsFormatException,
      );
    });

    test('requires a matching provider whenever a credential is supplied', () {
      expect(
        () => _parse({
          'version': 1,
          'credentials': {'tracking_token': 'secret'},
        }),
        throwsFormatException,
      );
      expect(
        () => _parse({
          'version': 1,
          'credentials': {'debrid_credential': 'secret'},
        }),
        throwsFormatException,
      );
    });

    test('keeps legacy v1 bundles compatible when Discord is omitted', () {
      final bundle = _parse({
        'version': 1,
        'preferences': {'downloads': true},
      });

      expect(bundle.preferences.linkDiscord, isNull);
      expect(bundle.preferences.choiceCount, 1);
    });

    test('never accepts Discord passwords or tokens as credentials', () {
      for (final field in const ['discord_password', 'discord_token']) {
        expect(
          () => _parse({
            'version': 1,
            'preferences': {'link_discord': true},
            'credentials': {field: 'must-not-be-accepted'},
          }),
          throwsFormatException,
          reason: '$field must stay outside the phone-setup protocol',
        );
      }
    });

    test(
      'normalizes valid credentials but rejects blank, short, control, and huge values',
      () {
        final bundle = _parse({
          'version': 1,
          'preferences': {'tracking_provider': 'myanimelist'},
          'credentials': {'tracking_token': '  valid-token  '},
        });
        expect(bundle.credentials.trackingToken, 'valid-token');

        for (final credential in <String>[
          '    ',
          '  x  ',
          'abc',
          'abcd\n',
          'x' * 4097,
        ]) {
          expect(
            () => _parse({
              'version': 1,
              'preferences': {'tracking_provider': 'anilist'},
              'credentials': {'tracking_token': credential},
            }),
            throwsFormatException,
            reason: 'credential ${jsonEncode(credential)} must be rejected',
          );
        }
      },
    );
  });

  group('saved setup key and envelope base64 validation', () {
    test('round-trips exact 32-byte key components', () {
      final original = PhoneSetupKeyMaterial(
        privateD: List<int>.generate(32, (index) => index),
        publicX: List<int>.generate(32, (index) => index + 32),
        publicY: List<int>.generate(32, (index) => index + 64),
      );
      final restored = PhoneSetupKeyMaterial.fromJson(original.toJson());

      expect(restored.privateD, original.privateD);
      expect(restored.publicX, original.publicX);
      expect(restored.publicY, original.publicY);
      expect(base64Url.decode(base64Url.normalize(restored.encodedPublicKey)), [
        0x04,
        ...original.publicX,
        ...original.publicY,
      ]);
    });

    test('rejects malformed and wrong-length key components', () {
      expect(
        () => PhoneSetupKeyMaterial.fromJson({'d': '', 'x': '', 'y': ''}),
        throwsFormatException,
      );
      expect(
        () => PhoneSetupKeyMaterial.fromJson({
          'd': _b64(List<int>.filled(31, 1)),
          'x': _b64(List<int>.filled(32, 2)),
          'y': _b64(List<int>.filled(32, 3)),
        }),
        throwsFormatException,
      );
    });

    test('enforces decoded envelope byte bounds', () {
      expect(
        decodeSetupBase64Url(
          _b64(List<int>.filled(12, 7)),
          minimum: 12,
          maximum: 12,
          label: 'nonce',
        ),
        hasLength(12),
      );
      expect(
        () => decodeSetupBase64Url(
          _b64(List<int>.filled(11, 7)),
          minimum: 12,
          maximum: 12,
          label: 'nonce',
        ),
        throwsFormatException,
      );
      expect(
        () => decodeSetupBase64Url(
          'not base64 ***',
          minimum: 1,
          maximum: 12,
          label: 'nonce',
        ),
        throwsFormatException,
      );
    });
  });
}

PhoneSetupBundle _parse(Map<String, Object?> value) =>
    PhoneSetupBundle.parse(utf8.encode(jsonEncode(value)));

String _b64(List<int> value) => base64UrlEncode(value).replaceAll('=', '');
