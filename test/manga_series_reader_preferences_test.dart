import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/manga/application/manga_series_preferences_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = MangaReaderSeriesKey(
    sourceId: 'source-a',
    publicationId: 'book-a',
  );
  const defaults = MangaReaderPreferences(
    mode: MangaReadingMode.vertical,
    direction: MangaReadingDirection.leftToRight,
    spreadMode: MangaSpreadMode.single,
    pageFit: MangaPageFit.width,
    loaded: true,
  );

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('series keys use both source and publication value equality', () {
    const same = MangaReaderSeriesKey(
      sourceId: 'source-a',
      publicationId: 'book-a',
    );
    const otherSource = MangaReaderSeriesKey(
      sourceId: 'source-b',
      publicationId: 'book-a',
    );
    const otherBook = MangaReaderSeriesKey(
      sourceId: 'source-a',
      publicationId: 'book-b',
    );
    expect(key, same);
    expect(key.hashCode, same.hashCode);
    final identities = {key, otherSource, otherBook};
    identities.add(same);
    expect(identities, hasLength(3));
  });

  test(
    'starts disabled with global defaults and enabling snapshots them',
    () async {
      var global = defaults;
      final controller = MangaSeriesReaderPreferencesController(
        const FlutterSecureStorage(),
        key,
        globalPreferences: () => global,
      );
      addTearDown(controller.dispose);
      expect(controller.state.loaded, isFalse);
      expect(controller.state.enabled, isFalse);
      expect(controller.state.mode, defaults.mode);
      await controller.load();
      expect(controller.state.loaded, isTrue);
      await controller.setEnabled(true);
      global = global.copyWith(mode: MangaReadingMode.webtoon);
      controller.refreshGlobalDefaults();
      expect(controller.state.enabled, isTrue);
      expect(controller.state.mode, MangaReadingMode.vertical);
      expect(controller.state.direction, defaults.direction);
      expect(controller.state.spreadMode, defaults.spreadMode);
      expect(controller.state.pageFit, defaults.pageFit);
    },
  );

  test(
    'disabled overrides follow current global defaults and delete storage',
    () async {
      var global = defaults;
      const storage = FlutterSecureStorage();
      final controller = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => global,
      );
      addTearDown(controller.dispose);
      await controller.setMode(MangaReadingMode.webtoon);
      await controller.reset();
      global = global.copyWith(
        mode: MangaReadingMode.paged,
        pageFit: MangaPageFit.height,
      );
      controller.refreshGlobalDefaults();
      expect(controller.state.enabled, isFalse);
      expect(controller.state.mode, MangaReadingMode.paged);
      expect(controller.state.pageFit, MangaPageFit.height);
      expect(await storage.readAll(), isEmpty);
      await controller.setEnabled(true);
      expect(controller.state.mode, MangaReadingMode.paged);
      expect(controller.state.pageFit, MangaPageFit.height);
    },
  );

  test(
    'layout persists across chapter/controller changes and source isolation',
    () async {
      const storage = FlutterSecureStorage();
      final firstChapter = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      await firstChapter.setEnabled(true);
      await firstChapter.setMode(MangaReadingMode.webtoon);
      await firstChapter.setDirection(MangaReadingDirection.rightToLeft);
      await firstChapter.setSpreadMode(MangaSpreadMode.double);
      await firstChapter.setPageFit(MangaPageFit.height);
      firstChapter.dispose();

      final nextChapter = MangaSeriesReaderPreferencesController(
        storage,
        const MangaReaderSeriesKey(
          sourceId: 'source-a',
          publicationId: 'book-a',
        ),
        globalPreferences: () => defaults,
      );
      addTearDown(nextChapter.dispose);
      await nextChapter.load();
      expect(nextChapter.state.enabled, isTrue);
      expect(nextChapter.state.mode, MangaReadingMode.webtoon);
      expect(nextChapter.state.direction, MangaReadingDirection.rightToLeft);
      expect(nextChapter.state.spreadMode, MangaSpreadMode.double);
      expect(nextChapter.state.pageFit, MangaPageFit.height);

      for (final other in const [
        MangaReaderSeriesKey(sourceId: 'source-b', publicationId: 'book-a'),
        MangaReaderSeriesKey(sourceId: 'source-a', publicationId: 'book-b'),
      ]) {
        final isolated = MangaSeriesReaderPreferencesController(
          storage,
          other,
          globalPreferences: () => defaults,
        );
        addTearDown(isolated.dispose);
        await isolated.load();
        expect(isolated.state.enabled, isFalse);
        expect(isolated.state.mode, defaults.mode);
      }
    },
  );

  test(
    'storage hashes identity and persists layout only, not URLs or privacy',
    () async {
      const storage = FlutterSecureStorage();
      final controller = MangaSeriesReaderPreferencesController(
        storage,
        const MangaReaderSeriesKey(
          sourceId: 'private-source',
          publicationId: 'https://example.invalid/title?token=private-token',
        ),
        globalPreferences: () => defaults.copyWith(showDiscordTitle: false),
      );
      addTearDown(controller.dispose);
      await controller.setEnabled(true);
      final entries = await storage.readAll();
      expect(entries, hasLength(1));
      expect(
        entries.keys.single,
        matches(r'^manga_reader_series_v1_[a-f0-9]{64}$'),
      );
      expect(jsonDecode(entries.values.single), {
        'enabled': true,
        'mode': 'vertical',
        'direction': 'leftToRight',
        'spread': 'single',
        'fit': 'width',
      });
      expect(entries.toString(), isNot(contains('private-token')));
      expect(entries.toString(), isNot(contains('example.invalid')));
      expect(entries.toString(), isNot(contains('private-source')));
      expect(entries.toString(), isNot(contains('discord')));
    },
  );

  test('identity encoding cannot collide on separators', () async {
    const storage = FlutterSecureStorage();
    for (final collisionCandidate in const [
      MangaReaderSeriesKey(sourceId: 'a:b', publicationId: 'c'),
      MangaReaderSeriesKey(sourceId: 'a', publicationId: 'b:c'),
    ]) {
      final controller = MangaSeriesReaderPreferencesController(
        storage,
        collisionCandidate,
        globalPreferences: () => defaults,
      );
      addTearDown(controller.dispose);
      await controller.setEnabled(true);
    }
    expect(await storage.readAll(), hasLength(2));
  });

  test(
    'malformed local override falls back to disabled global layout',
    () async {
      const storage = FlutterSecureStorage();
      final first = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      await first.setEnabled(true);
      first.dispose();
      final storageKey = (await storage.readAll()).keys.single;
      await storage.write(key: storageKey, value: '{broken');
      final restored = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.state.loaded, isTrue);
      expect(restored.state.enabled, isFalse);
      expect(restored.state.mode, defaults.mode);
    },
  );

  test(
    'invalid saved layout enums fall back to corresponding global values',
    () async {
      const storage = FlutterSecureStorage();
      final first = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      await first.setEnabled(true);
      first.dispose();
      final storageKey = (await storage.readAll()).keys.single;
      await storage.write(
        key: storageKey,
        value: jsonEncode({
          'enabled': true,
          'mode': 999,
          'direction': 'invalid',
          'spread': null,
          'fit': ['width'],
        }),
      );
      final restored = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.state.enabled, isTrue);
      expect(restored.state.mode, defaults.mode);
      expect(restored.state.direction, defaults.direction);
      expect(restored.state.spreadMode, defaults.spreadMode);
      expect(restored.state.pageFit, defaults.pageFit);
    },
  );

  test(
    'effective provider replaces only layout and follows disabled global values',
    () async {
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(const FlutterSecureStorage()),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        mangaEffectiveReaderPreferencesProvider(key),
        (_, _) {},
      );
      addTearDown(subscription.close);
      final global = container.read(mangaReaderPreferencesProvider.notifier);
      await global.load();
      await global.setShowDiscordTitle(false);
      await global.setWarmth(.5);
      await global.setSidePadding(24);
      await global.setDoubleTapZoom(false);
      final series = container.read(
        mangaSeriesReaderPreferencesProvider(key).notifier,
      );
      await series.load();
      await series.setMode(MangaReadingMode.webtoon);
      var effective = container.read(
        mangaEffectiveReaderPreferencesProvider(key),
      );
      expect(effective.mode, MangaReadingMode.webtoon);
      expect(effective.loaded, isTrue);
      expect(effective.showDiscordTitle, isFalse);
      expect(effective.warmth, .5);
      expect(effective.sidePadding, 24);
      expect(effective.doubleTapZoom, isFalse);
      await global.setMode(MangaReadingMode.vertical);
      expect(
        container.read(mangaEffectiveReaderPreferencesProvider(key)).mode,
        MangaReadingMode.webtoon,
      );
      await series.setEnabled(false);
      await global.setMode(MangaReadingMode.paged);
      effective = container.read(mangaEffectiveReaderPreferencesProvider(key));
      expect(effective.mode, MangaReadingMode.paged);
      expect(effective.showDiscordTitle, isFalse);
      expect(
        container.read(mangaSeriesReaderPreferencesProvider(key)).mode,
        MangaReadingMode.paged,
      );
    },
  );

  test(
    'a failed series edit cannot erase another pending edit or persist later',
    () async {
      final storage = _SeriesGatedStorage();
      final controller = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      addTearDown(controller.dispose);
      await controller.setEnabled(true);
      storage.failNextWrite = true;
      storage.pauseNextWrite = true;
      final failed = controller.setMode(MangaReadingMode.webtoon);
      await storage.writeStarted.future;
      final pending = controller.setPageFit(MangaPageFit.height);
      expect(controller.state.mode, MangaReadingMode.webtoon);
      expect(controller.state.pageFit, MangaPageFit.height);
      storage.releaseWrite.complete();
      await failed;
      expect(controller.state.mode, defaults.mode);
      expect(controller.state.pageFit, MangaPageFit.height);
      await pending;
      final restored = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.state.mode, defaults.mode);
      expect(restored.state.pageFit, MangaPageFit.height);
    },
  );

  test('effective layout retains the global privacy loading barrier', () async {
    final container = ProviderContainer(
      overrides: [
        mangaReaderPreferencesProvider.overrideWith(
          (ref) => _FixedGlobalPreferencesController(
            const MangaReaderPreferences(
              loaded: false,
              showDiscordTitle: false,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      mangaEffectiveReaderPreferencesProvider(key),
      (_, _) {},
    );
    addTearDown(subscription.close);
    final series = container.read(
      mangaSeriesReaderPreferencesProvider(key).notifier,
    );
    await series.load();
    await series.setMode(MangaReadingMode.webtoon);
    final effective = container.read(
      mangaEffectiveReaderPreferencesProvider(key),
    );
    expect(effective.mode, MangaReadingMode.webtoon);
    expect(effective.loaded, isFalse);
    expect(effective.showDiscordTitle, isFalse);
  });

  test(
    'chapter listener gaps retain pending layout until storage settles',
    () async {
      final storage = _SeriesGatedStorage();
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);
      final firstChapter = container.listen(
        mangaEffectiveReaderPreferencesProvider(key),
        (_, _) {},
      );
      final series = container.read(
        mangaSeriesReaderPreferencesProvider(key).notifier,
      );
      await series.load();
      await series.setEnabled(true);
      storage.pauseNextWrite = true;
      final pending = series.setMode(MangaReadingMode.webtoon);
      await storage.writeStarted.future;
      firstChapter.close();
      await container.pump();
      final nextChapter = container.listen(
        mangaEffectiveReaderPreferencesProvider(key),
        (_, _) {},
      );
      addTearDown(nextChapter.close);
      expect(
        container.read(mangaSeriesReaderPreferencesProvider(key).notifier),
        same(series),
      );
      expect(
        container.read(mangaEffectiveReaderPreferencesProvider(key)).mode,
        MangaReadingMode.webtoon,
      );
      storage.releaseWrite.complete();
      await pending;
    },
  );

  test('reset queued behind an old layout save removes the override', () async {
    final storage = _SeriesGatedStorage();
    final controller = MangaSeriesReaderPreferencesController(
      storage,
      key,
      globalPreferences: () => defaults,
    );
    addTearDown(controller.dispose);
    await controller.setEnabled(true);
    storage.pauseNextWrite = true;
    final old = controller.setMode(MangaReadingMode.webtoon);
    await storage.writeStarted.future;
    final reset = controller.reset();
    expect(controller.state.enabled, isFalse);
    expect(controller.state.mode, defaults.mode);
    storage.releaseWrite.complete();
    await Future.wait([old, reset]);
    expect(await storage.readAll(), isEmpty);
  });

  test(
    'pending writes finish after disposal for the next chapter to restore',
    () async {
      final storage = _SeriesGatedStorage();
      final first = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      await first.setEnabled(true);
      storage.pauseNextWrite = true;
      final pending = first.setMode(MangaReadingMode.webtoon);
      await storage.writeStarted.future;
      first.dispose();
      storage.releaseWrite.complete();
      await pending;
      final restored = MangaSeriesReaderPreferencesController(
        storage,
        key,
        globalPreferences: () => defaults,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.state.mode, MangaReadingMode.webtoon);
    },
  );
}

class _FixedGlobalPreferencesController
    extends MangaReaderPreferencesController {
  _FixedGlobalPreferencesController(MangaReaderPreferences preferences)
    : super(const FlutterSecureStorage()) {
    state = preferences;
  }

  @override
  Future<void> load() async {}
}

class _SeriesGatedStorage extends FlutterSecureStorage {
  bool pauseNextWrite = false;
  bool failNextWrite = false;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final fail = failNextWrite;
    failNextWrite = false;
    if (pauseNextWrite) {
      pauseNextWrite = false;
      writeStarted.complete();
      await releaseWrite.future;
    }
    if (fail) throw StateError('Write denied');
    await super.write(key: key, value: value);
  }
}
