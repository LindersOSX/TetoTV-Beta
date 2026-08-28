import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('fresh installs contain no torrent source manifests', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async {},
    );

    await controller.load();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.manifestUrls, isEmpty);
  });

  test('only an explicit public manifest is persisted', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async {},
    );
    await controller.load();

    expect(
      await controller.add('https://example.com/user-addon/manifest.json'),
      isNull,
    );
    expect(controller.state.manifestUrls, [
      'https://example.com/user-addon/manifest.json',
    ]);

    final restarted = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async {},
    );
    await restarted.load();
    expect(restarted.state.manifestUrls, controller.state.manifestUrls);
  });

  test('rejects local, private, and non-manifest targets', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async {},
    );
    await controller.load();

    for (final value in [
      'http://example.com/manifest.json',
      'https://localhost/manifest.json',
      'https://192.168.1.8/manifest.json',
      'https://[::ffff:127.0.0.1]/manifest.json',
      'https://example.com/catalog.json',
    ]) {
      expect(await controller.add(value), isNotNull, reason: value);
    }
    expect(controller.state.manifestUrls, isEmpty);
  });

  test('does not persist a hostname rejected by DNS validation', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async => throw const FormatException('private'),
    );
    await controller.load();

    expect(
      await controller.add('https://rebinding.example/manifest.json'),
      contains('public HTTPS'),
    );
    expect(controller.state.manifestUrls, isEmpty);
  });

  test('bulk add accepts whitespace-separated manifests in one pass', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = UserTorrentSourcesController(
      storage,
      targetValidator: (_) async {},
    );

    final result = await controller.addAll('''
https://one.example/addon/manifest.json
https://two.example/addon/manifest.json https://one.example/addon/manifest.json
https://bad.example/catalog.json
''');

    expect(result.added, 2);
    expect(result.duplicates, 1);
    expect(result.rejectedCount, 1);
    expect(controller.state.manifestUrls, [
      'https://one.example/addon/manifest.json',
      'https://two.example/addon/manifest.json',
    ]);
  });
}
