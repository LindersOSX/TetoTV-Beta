import 'dart:convert';

import 'package:anime_tv/features/settings/data/phone_setup_crypto.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('secure phone setup cryptography', () {
    test(
      'generated P-256 material is complete and serializable',
      () async {
        final crypto = SecurePhoneSetupCryptography();
        final key = await crypto.generateKeyMaterial();

        expect(key.privateD, hasLength(32));
        expect(key.publicX, hasLength(32));
        expect(key.publicY, hasLength(32));
        expect(_decode(key.encodedPublicKey), hasLength(65));
        expect(_decode(key.encodedPublicKey).first, 0x04);

        final restored = PhoneSetupKeyMaterial.fromJson(key.toJson());
        expect(restored.privateD, key.privateD);
        expect(restored.encodedPublicKey, key.encodedPublicKey);
      },
      skip: _nativeP256Reason,
    );

    test(
      'decrypts an independently browser-encrypted WebCrypto-compatible bundle',
      () async {
        final crypto = SecurePhoneSetupCryptography();
        final deviceKey = await crypto.generateKeyMaterial();
        const pairingId = 'pairing_1234567890';
        final cleartext = utf8.encode(
          jsonEncode({
            'version': 3,
            'preferences': {
              'preferred_audio': 'sub',
              'title_language': 'romaji',
              'tracking_provider': 'anilist',
              'debrid_provider': 'torbox',
            },
            'sources': {
              'repository_urls': ['https://example.test/repository.json'],
              'manifest_urls': ['https://example.test/manifest.json'],
            },
            'credentials': {
              'tracking': {
                'provider': 'anilist',
                'access_token': 'tracker-secret',
              },
              'debrid': {'provider': 'torbox', 'api_key': 'debrid-secret'},
              'discord': {
                'access_token': 'discord-access',
                'refresh_token': 'discord-refresh',
                'token_type': 1,
                'expires_at': 2000000000,
                'scopes': ['openid', 'sdk.social_layer_presence'],
                'minimum_age_confirmation': {'version': 1, 'confirmed': true},
              },
            },
          }),
        );
        final envelope = await _browserEncrypt(
          pairingId: pairingId,
          deviceKey: deviceKey,
          cleartext: cleartext,
        );

        final bundle = await crypto.decrypt(
          pairingId: pairingId,
          deviceKey: deviceKey,
          envelope: envelope,
        );

        expect(bundle.preferences.preferredAudio, 'sub');
        expect(bundle.preferences.titleLanguage, 'romaji');
        expect(bundle.preferences.trackingProvider, 'anilist');
        expect(bundle.preferences.debridProvider, 'torbox');
        expect(bundle.repositoryUrls, ['https://example.test/repository.json']);
        expect(bundle.manifestUrls, ['https://example.test/manifest.json']);
        expect(bundle.protocolVersion, 3);
        expect(bundle.credentials.tracking?.accessToken, 'tracker-secret');
        expect(bundle.credentials.debrid?.apiKey, 'debrid-secret');
        expect(bundle.credentials.discord?.accessToken, 'discord-access');
      },
      skip: _nativeP256Reason,
    );

    test(
      'rejects ciphertext, tag, nonce, and pairing-context tampering',
      () async {
        final crypto = SecurePhoneSetupCryptography();
        final deviceKey = await crypto.generateKeyMaterial();
        const pairingId = 'pairing_1234567890';
        final envelope = await _browserEncrypt(
          pairingId: pairingId,
          deviceKey: deviceKey,
          cleartext: utf8.encode('{"version":1}'),
        );

        for (final tampered in <PhoneSetupEncryptedSubmission>[
          PhoneSetupEncryptedSubmission(
            browserPublicKey: envelope.browserPublicKey,
            nonce: envelope.nonce,
            ciphertext: [
              envelope.ciphertext.first ^ 0x01,
              ...envelope.ciphertext.skip(1),
            ],
          ),
          PhoneSetupEncryptedSubmission(
            browserPublicKey: envelope.browserPublicKey,
            nonce: envelope.nonce,
            ciphertext: [
              ...envelope.ciphertext.take(envelope.ciphertext.length - 1),
              envelope.ciphertext.last ^ 0x01,
            ],
          ),
          PhoneSetupEncryptedSubmission(
            browserPublicKey: envelope.browserPublicKey,
            nonce: [envelope.nonce.first ^ 0x01, ...envelope.nonce.skip(1)],
            ciphertext: envelope.ciphertext,
          ),
        ]) {
          await expectLater(
            crypto.decrypt(
              pairingId: pairingId,
              deviceKey: deviceKey,
              envelope: tampered,
            ),
            throwsA(isA<FormatException>()),
          );
        }

        await expectLater(
          crypto.decrypt(
            pairingId: 'pairing_abcdefghij',
            deviceKey: deviceKey,
            envelope: envelope,
          ),
          throwsA(isA<FormatException>()),
        );
      },
      skip: _nativeP256Reason,
    );

    test(
      'rejects malformed protocol inputs before doing key agreement',
      () async {
        final crypto = SecurePhoneSetupCryptography();
        final deviceKey = PhoneSetupKeyMaterial(
          privateD: List<int>.filled(32, 1),
          publicX: List<int>.filled(32, 2),
          publicY: List<int>.filled(32, 3),
        );
        final validEnvelope = PhoneSetupEncryptedSubmission(
          browserPublicKey: [0x04, ...List<int>.filled(64, 1)],
          nonce: List<int>.filled(12, 2),
          ciphertext: List<int>.filled(17, 3),
        );

        await expectLater(
          crypto.decrypt(
            pairingId: 'too-short',
            deviceKey: deviceKey,
            envelope: validEnvelope,
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          crypto.decrypt(
            pairingId: 'pairing_1234567890',
            deviceKey: deviceKey,
            envelope: PhoneSetupEncryptedSubmission(
              browserPublicKey: List<int>.filled(65, 1),
              nonce: List<int>.filled(12, 2),
              ciphertext: List<int>.filled(17, 3),
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          crypto.decrypt(
            pairingId: 'pairing_1234567890',
            deviceKey: deviceKey,
            envelope: PhoneSetupEncryptedSubmission(
              browserPublicKey: validEnvelope.browserPublicKey,
              nonce: List<int>.filled(11, 2),
              ciphertext: validEnvelope.ciphertext,
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          crypto.decrypt(
            pairingId: 'pairing_1234567890',
            deviceKey: deviceKey,
            envelope: PhoneSetupEncryptedSubmission(
              browserPublicKey: validEnvelope.browserPublicKey,
              nonce: validEnvelope.nonce,
              ciphertext: List<int>.filled(16, 3),
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });
}

const _nativeP256Reason =
    'P-256 is provided by the app-owned Android JCA bridge and is covered by '
    'integration_test/phone_setup_crypto_integration_test.dart.';

Future<PhoneSetupEncryptedSubmission> _browserEncrypt({
  required String pairingId,
  required PhoneSetupKeyMaterial deviceKey,
  required List<int> cleartext,
}) async {
  final ecdh = Ecdh.p256(length: 32);
  final browserKey = await (await ecdh.newKeyPair()).extract();
  final devicePublicKey = EcPublicKey(
    x: deviceKey.publicX,
    y: deviceKey.publicY,
    type: KeyPairType.p256,
  );
  final sharedSecret = await ecdh.sharedSecretKey(
    keyPair: browserKey,
    remotePublicKey: devicePublicKey,
  );
  final context = utf8.encode(pairingId);
  final aesKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: sharedSecret,
    nonce: context,
    info: utf8.encode('tetotv-setup-v1'),
  );
  final nonce = List<int>.generate(12, (index) => index + 1);
  final box = await AesGcm.with256bits().encrypt(
    cleartext,
    secretKey: aesKey,
    nonce: nonce,
    aad: context,
  );
  final publicKey = [0x04, ...browserKey.x, ...browserKey.y];
  browserKey.destroy();
  sharedSecret.destroy();
  aesKey.destroy();
  return PhoneSetupEncryptedSubmission(
    browserPublicKey: publicKey,
    nonce: nonce,
    ciphertext: [...box.cipherText, ...box.mac.bytes],
  );
}

List<int> _decode(String value) => base64Url.decode(base64Url.normalize(value));
