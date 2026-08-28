import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/settings/data/phone_setup_crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.tetotv/android_tv');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('P-256 adapter preserves fixed-width unsigned bridge values', () async {
    final highBit = Uint8List.fromList([0x80, ...List<int>.filled(31, 0)]);
    final lowBit = Uint8List.fromList([0x01, ...List<int>.filled(31, 0)]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'generatePhoneSetupP256KeyPair');
      return <String, Object?>{'d': highBit, 'x': lowBit, 'y': highBit};
    });

    final key = await (await AndroidPhoneSetupP256Ecdh().newKeyPair())
        .extract();

    expect(key.d, hasLength(32));
    expect(key.x, hasLength(32));
    expect(key.y, hasLength(32));
    expect(key.d.first, 0x80);
    expect(key.y.first, 0x80);
    key.destroy();
  });

  test(
    'P-256 adapter sends canonical components and accepts 32-byte secret',
    () async {
      final local = EcKeyPairData(
        d: List<int>.filled(32, 1),
        x: List<int>.filled(32, 2),
        y: List<int>.filled(32, 3),
        type: KeyPairType.p256,
      );
      final remote = EcPublicKey(
        x: [0x80, ...List<int>.filled(31, 4)],
        y: List<int>.filled(32, 5),
        type: KeyPairType.p256,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'derivePhoneSetupP256SharedSecret');
        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments['privateD'], isA<Uint8List>());
        expect(arguments['localX'], isA<Uint8List>());
        expect(arguments['localY'], isA<Uint8List>());
        expect(arguments['remoteX'], isA<Uint8List>());
        expect((arguments['remoteX'] as Uint8List).first, 0x80);
        return Uint8List.fromList(List<int>.generate(32, (index) => index));
      });

      final secret = await AndroidPhoneSetupP256Ecdh().sharedSecretKey(
        keyPair: local,
        remotePublicKey: remote,
      );

      expect(await secret.extractBytes(), List<int>.generate(32, (i) => i));
      local.destroy();
      secret.destroy();
    },
  );

  test('bridge rejects malformed native output and Dart input', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'generatePhoneSetupP256KeyPair') {
        return <String, Object?>{
          'd': Uint8List(31),
          'x': Uint8List(32),
          'y': Uint8List(32),
        };
      }
      fail('Malformed Dart input must not reach the platform channel.');
    });

    await expectLater(
      AndroidTvBridge.instance.generatePhoneSetupP256KeyPair(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'PHONE_SETUP_CRYPTO_OUTPUT',
        ),
      ),
    );
    await expectLater(
      AndroidTvBridge.instance.derivePhoneSetupP256SharedSecret(
        privateD: List<int>.filled(31, 1),
        localX: List<int>.filled(32, 2),
        localY: List<int>.filled(32, 3),
        remoteX: List<int>.filled(32, 4),
        remoteY: List<int>.filled(32, 5),
      ),
      throwsArgumentError,
    );
  });

  test(
    'invalid native browser point becomes a protocol format error',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'PHONE_SETUP_CRYPTO_INPUT',
          message: 'invalid',
        );
      });
      final local = EcKeyPairData(
        d: List<int>.filled(32, 1),
        x: List<int>.filled(32, 2),
        y: List<int>.filled(32, 3),
        type: KeyPairType.p256,
      );

      await expectLater(
        AndroidPhoneSetupP256Ecdh().sharedSecretKey(
          keyPair: local,
          remotePublicKey: EcPublicKey(
            x: List<int>.filled(32, 4),
            y: List<int>.filled(32, 5),
            type: KeyPairType.p256,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      local.destroy();
    },
  );
}
