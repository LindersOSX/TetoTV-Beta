import 'dart:convert';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/settings/domain/phone_setup_pairing.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class PhoneSetupCryptography {
  Future<PhoneSetupKeyMaterial> generateKeyMaterial();

  Future<PhoneSetupBundle> decrypt({
    required String pairingId,
    required PhoneSetupKeyMaterial deviceKey,
    required PhoneSetupEncryptedSubmission envelope,
  });
}

/// P-256 backed by TetoTV's audited Android JCA bridge.
///
/// Unlike `cryptography_flutter` 2.3.4, the bridge treats every scalar and
/// coordinate as an unsigned, fixed-width value and validates browser points
/// before key agreement.
class AndroidPhoneSetupP256Ecdh extends Ecdh {
  AndroidPhoneSetupP256Ecdh({AndroidTvBridge? bridge})
    : _bridge = bridge ?? AndroidTvBridge.instance,
      super.constructor();

  final AndroidTvBridge _bridge;

  @override
  KeyPairType get keyPairType => KeyPairType.p256;

  @override
  Future<EcKeyPair> newKeyPair() async {
    final key = await _bridge.generatePhoneSetupP256KeyPair();
    return EcKeyPairData(
      d: key.privateD,
      x: key.publicX,
      y: key.publicY,
      type: KeyPairType.p256,
    );
  }

  @override
  Future<EcKeyPair> newKeyPairFromSeed(List<int> seed) {
    throw UnsupportedError(
      'Deterministic phone-setup P-256 keys are not supported.',
    );
  }

  @override
  Future<SecretKey> sharedSecretKey({
    required KeyPair keyPair,
    required PublicKey remotePublicKey,
  }) async {
    final local = await keyPair.extract();
    if (local is! EcKeyPairData ||
        local.type != KeyPairType.p256 ||
        remotePublicKey is! EcPublicKey ||
        remotePublicKey.type != KeyPairType.p256) {
      throw ArgumentError('P-256 key material is required.');
    }
    try {
      final bytes = await _bridge.derivePhoneSetupP256SharedSecret(
        privateD: local.d,
        localX: local.x,
        localY: local.y,
        remoteX: remotePublicKey.x,
        remoteY: remotePublicKey.y,
      );
      return SecretKeyData(bytes, overwriteWhenDestroyed: true);
    } on PlatformException catch (error) {
      if (error.code == 'PHONE_SETUP_CRYPTO_INPUT') {
        throw const FormatException('The browser P-256 key is invalid.');
      }
      rethrow;
    }
  }
}

Ecdh _defaultPhoneSetupEcdh() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidPhoneSetupP256Ecdh();
  }
  return Ecdh.p256(length: 32);
}

class SecurePhoneSetupCryptography implements PhoneSetupCryptography {
  SecurePhoneSetupCryptography({Ecdh? ecdh, Hkdf? hkdf, AesGcm? cipher})
    : _ecdh = ecdh ?? _defaultPhoneSetupEcdh(),
      _hkdf = hkdf ?? Hkdf(hmac: Hmac.sha256(), outputLength: _keyLengthBytes),
      _cipher = cipher ?? AesGcm.with256bits();

  static const _keyLengthBytes = 32;
  static const _publicKeyLengthBytes = 65;
  static const _nonceLengthBytes = 12;
  static const _tagLengthBytes = 16;
  static const _protocolInfo = 'tetotv-setup-v1';

  final Ecdh _ecdh;
  final Hkdf _hkdf;
  final AesGcm _cipher;

  @override
  Future<PhoneSetupKeyMaterial> generateKeyMaterial() async {
    final key = await (await _ecdh.newKeyPair()).extract();
    try {
      _checkComponent(key.d);
      _checkComponent(key.x);
      _checkComponent(key.y);
      return PhoneSetupKeyMaterial(
        privateD: List<int>.unmodifiable(key.d),
        publicX: List<int>.unmodifiable(key.x),
        publicY: List<int>.unmodifiable(key.y),
      );
    } finally {
      key.destroy();
    }
  }

  @override
  Future<PhoneSetupBundle> decrypt({
    required String pairingId,
    required PhoneSetupKeyMaterial deviceKey,
    required PhoneSetupEncryptedSubmission envelope,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(pairingId) ||
        envelope.browserPublicKey.length != _publicKeyLengthBytes ||
        envelope.browserPublicKey.first != 0x04 ||
        envelope.nonce.length != _nonceLengthBytes ||
        envelope.ciphertext.length <= _tagLengthBytes ||
        envelope.ciphertext.length > 64 * 1024 + _tagLengthBytes) {
      throw const FormatException('The encrypted phone setup is invalid.');
    }
    _checkComponent(deviceKey.privateD);
    _checkComponent(deviceKey.publicX);
    _checkComponent(deviceKey.publicY);
    final localKey = EcKeyPairData(
      d: deviceKey.privateD,
      x: deviceKey.publicX,
      y: deviceKey.publicY,
      type: KeyPairType.p256,
    );
    final remote = EcPublicKey(
      x: envelope.browserPublicKey.sublist(1, 33),
      y: envelope.browserPublicKey.sublist(33, 65),
      type: KeyPairType.p256,
    );
    final context = utf8.encode(pairingId);
    final split = envelope.ciphertext.length - _tagLengthBytes;
    SecretKey? shared;
    SecretKey? encryptionKey;
    try {
      shared = await _ecdh.sharedSecretKey(
        keyPair: localKey,
        remotePublicKey: remote,
      );
      encryptionKey = await _hkdf.deriveKey(
        secretKey: shared,
        nonce: context,
        info: utf8.encode(_protocolInfo),
      );
      final cleartext = await _cipher.decrypt(
        SecretBox(
          envelope.ciphertext.sublist(0, split),
          nonce: envelope.nonce,
          mac: Mac(envelope.ciphertext.sublist(split)),
        ),
        secretKey: encryptionKey,
        aad: context,
      );
      return PhoneSetupBundle.parse(cleartext);
    } on SecretBoxAuthenticationError {
      throw const FormatException(
        'The phone setup failed its encryption check. Create a new code.',
      );
    } finally {
      localKey.destroy();
      // Android's shared-secret adapter opts into overwrite-on-destroy. HKDF
      // keys can be opaque, so use the package's supported destroy contract
      // instead of trying to mutate its read-only SensitiveBytes view.
      shared?.destroy();
      encryptionKey?.destroy();
    }
  }

  void _checkComponent(List<int> value) {
    if (value.length != _keyLengthBytes ||
        value.any((byte) => byte < 0 || byte > 0xff)) {
      throw const FormatException('The phone-setup key is invalid.');
    }
  }
}
