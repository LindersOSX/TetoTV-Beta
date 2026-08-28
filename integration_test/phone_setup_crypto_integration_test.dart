import 'dart:convert';

import 'package:anime_tv/features/settings/data/phone_setup_crypto.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android P-256/HKDF/AES-GCM decrypts browser payload and rejects tampering',
    (_) async {
      final crypto = SecurePhoneSetupCryptography();
      final deviceKey = await crypto.generateKeyMaterial();
      expect(deviceKey.privateD, hasLength(32));
      expect(deviceKey.publicX, hasLength(32));
      expect(deviceKey.publicY, hasLength(32));

      const pairingId = 'pairing_1234567890';
      final envelope = await _browserEncrypt(
        pairingId: pairingId,
        deviceKey: deviceKey,
        cleartext: utf8.encode(
          jsonEncode({
            'version': 1,
            'preferences': {
              'preferred_audio': 'dub',
              'title_language': 'english',
              'watch_party': true,
              'tracking_provider': 'anilist',
              'debrid_provider': 'realdebrid',
            },
            'sources': {
              'repository_urls': ['https://example.test/repository.json'],
              'manifest_urls': ['https://example.test/manifest.json'],
            },
            'credentials': {
              'tracking_token': 'tracker-secret',
              'debrid_credential': 'debrid-secret',
            },
          }),
        ),
      );

      final bundle = await crypto.decrypt(
        pairingId: pairingId,
        deviceKey: deviceKey,
        envelope: envelope,
      );
      expect(bundle.preferences.preferredAudio, 'dub');
      expect(bundle.preferences.titleLanguage, 'english');
      expect(bundle.preferences.showWatchParty, isTrue);
      expect(bundle.repositoryUrls, ['https://example.test/repository.json']);
      expect(bundle.manifestUrls, ['https://example.test/manifest.json']);
      expect(bundle.credentials.trackingToken, 'tracker-secret');
      expect(bundle.credentials.debridCredential, 'debrid-secret');

      final tamperedCiphertext = List<int>.from(envelope.ciphertext)
        ..[0] ^= 0x01;
      await expectLater(
        crypto.decrypt(
          pairingId: pairingId,
          deviceKey: deviceKey,
          envelope: PhoneSetupEncryptedSubmission(
            browserPublicKey: envelope.browserPublicKey,
            nonce: envelope.nonce,
            ciphertext: tamperedCiphertext,
          ),
        ),
        throwsA(isA<FormatException>()),
      );

      await expectLater(
        crypto.decrypt(
          pairingId: 'pairing_abcdefghij',
          deviceKey: deviceKey,
          envelope: envelope,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  testWidgets(
    'Android imports unsigned high-bit Node WebCrypto P-256 fixture',
    (_) async {
      // Generated with Node's standards-based WebCrypto implementation. The
      // device scalar, both device coordinates, and the browser Y coordinate
      // start with their high bit set, exercising unsigned Java conversion.
      const pairingId = 'pairing_webcrypto_01';
      final deviceKey = PhoneSetupKeyMaterial(
        privateD: _base64UrlBytes(
          'n5WX7RDOGm8zp4i8q2aqUZexyERJXada4AwxGNjcmeY',
        ),
        publicX: _base64UrlBytes('2naHU38dIoHksDVj1A8-uTSnAUwzO4YeTRnFAl-pEao'),
        publicY: _base64UrlBytes('1Q4oTg4CTqCZrOuX72SAMdcInXgf0XM2oyxxukuuvRc'),
      );
      final envelope = PhoneSetupEncryptedSubmission(
        browserPublicKey: [
          0x04,
          ..._base64UrlBytes('fy5Ew7bcwIyR0FKmdUP8GjwrKgIqSASk4Kca9BikHFQ'),
          ..._base64UrlBytes('1uyszbpFfxRkdeViL-aeY7MFiPl_I_1W1_8fNjzXn2E'),
        ],
        nonce: _base64UrlBytes('oKGio6Slpqeoqaqr'),
        ciphertext: _base64UrlBytes(
          'ncHyiPqc9_O74D7MgKcUg_AupGZawQVw305XJZsW7_1_qQiqmIe2To1B7bG-JQ27'
          'xxgNRXO6yOMGvPG0XFRBAdLx7rk8Op_-WLKH7PSzvstU3iiY-CDwv0BuAMQaYLAg'
          'duXCO7_-ZGGRp-4QK5VgpDeYkTzq_6Slix3Ib4N_8N1CmU5yFhHwaNQgTlyGTn9'
          '_zz6xKYLnjBpmK9lWvDOxAypKOTlPgMBFc2nw9Cx3JmcwZU1IeIycRps1vHVyB3'
          'LYjQRKcpHLbYXdswbVfJ1SImam_--7urGykuRtUn9LiA-FNKLNVHKDyzosIH435T'
          '8kNk5_JJqrqAp-I8YbdSnX1QSrMtiX-o6V0o_peFHLA0lg-mi7mBVtTL9ARSEWT7'
          'ukDsfKNvFQ-3gD1Uha9Mq_-QWzpnkWR7TT5s4f8RBl-kRLQPBlQ1fygezMM-9ha'
          'ryiVWn0qNC3swdDOeBGj6cu',
        ),
      );

      final bundle = await SecurePhoneSetupCryptography().decrypt(
        pairingId: pairingId,
        deviceKey: deviceKey,
        envelope: envelope,
      );

      expect(bundle.preferences.preferredAudio, 'sub');
      expect(bundle.preferences.titleLanguage, 'romaji');
      expect(bundle.preferences.trackingProvider, 'anilist');
      expect(bundle.preferences.debridProvider, 'torbox');
      expect(bundle.repositoryUrls, ['https://fixture.test/repository.json']);
      expect(bundle.credentials.trackingToken, 'fixture-tracking');
      expect(bundle.credentials.debridCredential, 'fixture-debrid');
    },
  );
}

Future<PhoneSetupEncryptedSubmission> _browserEncrypt({
  required String pairingId,
  required PhoneSetupKeyMaterial deviceKey,
  required List<int> cleartext,
}) async {
  final ecdh = AndroidPhoneSetupP256Ecdh();
  final browserKey = await (await ecdh.newKeyPair()).extract();
  final sharedSecret = await ecdh.sharedSecretKey(
    keyPair: browserKey,
    remotePublicKey: EcPublicKey(
      x: deviceKey.publicX,
      y: deviceKey.publicY,
      type: KeyPairType.p256,
    ),
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
  final browserPublicKey = [0x04, ...browserKey.x, ...browserKey.y];
  browserKey.destroy();
  sharedSecret.destroy();
  aesKey.destroy();
  return PhoneSetupEncryptedSubmission(
    browserPublicKey: browserPublicKey,
    nonce: nonce,
    ciphertext: [...box.cipherText, ...box.mac.bytes],
  );
}

List<int> _base64UrlBytes(String value) =>
    base64Url.decode(base64Url.normalize(value));
