import 'dart:async';

import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('reader preferences persist and restore', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = MangaReaderPreferencesController(storage);

    await controller.setMode(MangaReadingMode.webtoon);
    await controller.setDirection(MangaReadingDirection.leftToRight);
    await controller.setSpreadMode(MangaSpreadMode.double);
    await controller.setPageFit(MangaPageFit.width);
    await controller.setBackground(MangaReaderBackground.charcoal);
    await controller.setPageGap(18);
    await controller.setPreloadPages(4);
    await controller.setCoverStartsAlone(false);
    await controller.setInvertDoublePages(true);
    await controller.setTapZonesEnabled(false);
    await controller.setBookAnimationEnabled(false);
    await controller.setKeepScreenAwake(false);
    await controller.setShowDiscordTitle(false);
    await controller.setSidePadding(32);
    await controller.setWebtoonGap(14);
    await controller.setDimAmount(.4);
    await controller.setWarmth(.6);
    await controller.setGrayscale(true);
    await controller.setInvertColors(true);
    await controller.setShowPageNumber(false);
    await controller.setDoubleTapZoom(false);
    await controller.setTapZoneLayout(MangaTapZoneLayout.edges);
    await controller.setInvertTapZones(true);

    final restored = MangaReaderPreferencesController(storage);
    await restored.load();

    expect(restored.state.loaded, isTrue);
    expect(restored.state.mode, MangaReadingMode.webtoon);
    expect(restored.state.direction, MangaReadingDirection.leftToRight);
    expect(restored.state.spreadMode, MangaSpreadMode.double);
    expect(restored.state.pageFit, MangaPageFit.width);
    expect(restored.state.background, MangaReaderBackground.charcoal);
    expect(restored.state.pageGap, 18);
    expect(restored.state.preloadPages, 4);
    expect(restored.state.coverStartsAlone, isFalse);
    expect(restored.state.invertDoublePages, isTrue);
    expect(restored.state.tapZonesEnabled, isFalse);
    expect(restored.state.bookAnimationEnabled, isFalse);
    expect(restored.state.keepScreenAwake, isFalse);
    expect(restored.state.showDiscordTitle, isFalse);
    expect(restored.state.sidePadding, 32);
    expect(restored.state.webtoonGap, 14);
    expect(restored.state.dimAmount, .4);
    expect(restored.state.warmth, .6);
    expect(restored.state.grayscale, isTrue);
    expect(restored.state.invertColors, isTrue);
    expect(restored.state.showPageNumber, isFalse);
    expect(restored.state.doubleTapZoom, isFalse);
    expect(restored.state.tapZoneLayout, MangaTapZoneLayout.edges);
    expect(restored.state.invertTapZones, isTrue);
  });

  test('invalid and unsafe stored values fall back or are bounded', () async {
    FlutterSecureStorage.setMockInitialValues({
      'manga_reader_v1_mode': 'not-a-mode',
      'manga_reader_v1_gap': '999',
      'manga_reader_v1_preload': '-10',
      'manga_reader_v1_cover_alone': 'maybe',
    });
    final controller = MangaReaderPreferencesController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state.mode, MangaReadingMode.paged);
    expect(controller.state.pageGap, 40);
    expect(controller.state.preloadPages, 0);
    expect(controller.state.coverStartsAlone, isTrue);
  });

  test('reset removes persisted reader choices', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = MangaReaderPreferencesController(storage);
    await controller.setMode(MangaReadingMode.vertical);
    await controller.setPageGap(30);
    await controller.setBackground(MangaReaderBackground.sepia);
    await controller.setSidePadding(60);
    await controller.setWebtoonGap(24);
    await controller.setDimAmount(.5);
    await controller.setWarmth(.9);
    await controller.setGrayscale(true);
    await controller.setInvertColors(true);
    await controller.setShowPageNumber(false);
    await controller.setDoubleTapZoom(false);
    await controller.setTapZoneLayout(MangaTapZoneLayout.edges);
    await controller.setInvertTapZones(true);

    await controller.reset();
    final restored = MangaReaderPreferencesController(storage);
    await restored.load();

    expect(restored.state, isA<MangaReaderPreferences>());
    expect(restored.state.mode, MangaReadingMode.paged);
    expect(restored.state.pageGap, 12);
    expect(restored.state.loaded, isTrue);
    expect(restored.state.background, MangaReaderBackground.black);
    expect(restored.state.sidePadding, 0);
    expect(restored.state.webtoonGap, 0);
    expect(restored.state.dimAmount, 0);
    expect(restored.state.warmth, 0);
    expect(restored.state.grayscale, isFalse);
    expect(restored.state.invertColors, isFalse);
    expect(restored.state.showPageNumber, isTrue);
    expect(restored.state.doubleTapZoom, isTrue);
    expect(restored.state.tapZoneLayout, MangaTapZoneLayout.thirds);
    expect(restored.state.invertTapZones, isFalse);
    expect(await storage.readAll(), isEmpty);
  });

  test('new stored values are finite, bounded and safely parsed', () async {
    FlutterSecureStorage.setMockInitialValues({
      'manga_reader_v1_background': 'sepia',
      'manga_reader_v1_gap': 'NaN',
      'manga_reader_v1_side_padding': '999',
      'manga_reader_v1_webtoon_gap': '-20',
      'manga_reader_v1_dim_amount': 'Infinity',
      'manga_reader_v1_warmth': '-Infinity',
      'manga_reader_v1_grayscale': 'invalid',
      'manga_reader_v1_page_number': 'invalid',
      'manga_reader_v1_double_tap_zoom': 'invalid',
      'manga_reader_v1_tap_zone_layout': 'invalid',
    });
    final controller = MangaReaderPreferencesController(
      const FlutterSecureStorage(),
    );
    await controller.load();

    expect(controller.state.background, MangaReaderBackground.sepia);
    expect(controller.state.background.colorValue, 0xFFF1E7D0);
    expect(controller.state.pageGap, 12);
    expect(controller.state.sidePadding, 80);
    expect(controller.state.webtoonGap, 0);
    expect(controller.state.dimAmount, 0);
    expect(controller.state.warmth, 0);
    expect(controller.state.grayscale, isFalse);
    expect(controller.state.showPageNumber, isTrue);
    expect(controller.state.doubleTapZoom, isTrue);
    expect(controller.state.tapZoneLayout, MangaTapZoneLayout.thirds);
  });

  test('numeric setters clamp ranges and reject non-finite input', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = MangaReaderPreferencesController(
      const FlutterSecureStorage(),
    );
    await controller.setSidePadding(100);
    await controller.setWebtoonGap(100);
    await controller.setDimAmount(1);
    await controller.setWarmth(2);
    expect(controller.state.sidePadding, 80);
    expect(controller.state.webtoonGap, 40);
    expect(controller.state.dimAmount, .7);
    expect(controller.state.warmth, 1);
    await controller.setPageGap(double.nan);
    await controller.setSidePadding(double.infinity);
    await controller.setWebtoonGap(double.negativeInfinity);
    await controller.setDimAmount(double.nan);
    await controller.setWarmth(-1);
    expect(controller.state.pageGap, 12);
    expect(controller.state.sidePadding, 0);
    expect(controller.state.webtoonGap, 0);
    expect(controller.state.dimAmount, 0);
    expect(controller.state.warmth, 0);
  });

  test('reset waits for older writes and cannot resurrect them', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = _GatedSecureStorage('manga_reader_v1_side_padding');
    final controller = MangaReaderPreferencesController(storage);
    await controller.load();
    final oldSave = controller.setSidePadding(64);
    await storage.writeStarted.future;
    final reset = controller.reset();
    expect(controller.state.sidePadding, 0);
    storage.releaseWrite.complete();
    await Future.wait([oldSave, reset]);

    final restored = MangaReaderPreferencesController(storage);
    await restored.load();
    expect(restored.state.sidePadding, 0);
    expect(await storage.readAll(), isEmpty);
  });

  test('a newer save survives reset while an older save is pending', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = _GatedSecureStorage('manga_reader_v1_webtoon_gap');
    final controller = MangaReaderPreferencesController(storage);
    await controller.load();
    final oldSave = controller.setWebtoonGap(30);
    await storage.writeStarted.future;
    final reset = controller.reset();
    final newSave = controller.setWebtoonGap(8);
    final otherSave = controller.setGrayscale(true);
    expect(controller.state.webtoonGap, 8);
    expect(controller.state.grayscale, isTrue);
    storage.releaseWrite.complete();
    await Future.wait([oldSave, reset, newSave, otherSave]);

    final restored = MangaReaderPreferencesController(storage);
    await restored.load();
    expect(restored.state.webtoonGap, 8);
    expect(restored.state.grayscale, isTrue);
  });

  test(
    'a failed setting preserves a different pending optimistic edit',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = _GatedSecureStorage(
        'manga_reader_v1_warmth',
        failedWriteKey: 'manga_reader_v1_grayscale',
      );
      final controller = MangaReaderPreferencesController(storage);
      await controller.load();
      final warmth = controller.setWarmth(.8);
      await storage.writeStarted.future;
      await controller.setGrayscale(true);
      expect(controller.state.grayscale, isFalse);
      expect(controller.state.warmth, .8);
      storage.releaseWrite.complete();
      await warmth;
      expect(controller.state.warmth, .8);
    },
  );

  test('failed reset deletion restores only its own setting', () async {
    FlutterSecureStorage.setMockInitialValues({
      'manga_reader_v1_warmth': '0.8',
      'manga_reader_v1_grayscale': 'true',
    });
    final storage = _GatedSecureStorage(
      'unused',
      failedDeleteKey: 'manga_reader_v1_warmth',
    );
    final controller = MangaReaderPreferencesController(storage);
    await controller.load();
    await controller.reset();
    expect(controller.state.warmth, .8);
    expect(controller.state.grayscale, isFalse);
    final restored = MangaReaderPreferencesController(storage);
    await restored.load();
    expect(restored.state.warmth, .8);
    expect(restored.state.grayscale, isFalse);
  });

  test(
    'loading once cannot replace a pending edit with stale storage',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = _GatedSecureStorage('manga_reader_v1_side_padding');
      final controller = MangaReaderPreferencesController(storage);
      await controller.load();
      final save = controller.setSidePadding(36);
      await storage.writeStarted.future;
      await controller.load();
      expect(controller.state.sidePadding, 36);
      storage.releaseWrite.complete();
      await save;
    },
  );

  test('failed protected write restores the last durable value', () async {
    FlutterSecureStorage.setMockInitialValues({
      'manga_reader_v1_mode': MangaReadingMode.vertical.name,
    });
    final storage = _ControlledSecureStorage(<bool>[false]);
    final controller = MangaReaderPreferencesController(storage);
    await controller.load();

    expect(controller.state.mode, MangaReadingMode.vertical);
    await controller.setMode(MangaReadingMode.webtoon);

    expect(controller.state.mode, MangaReadingMode.vertical);
    final restored = MangaReaderPreferencesController(
      const FlutterSecureStorage(),
    );
    await restored.load();
    expect(restored.state.mode, MangaReadingMode.vertical);
  });

  test(
    'rapid writes serialize and a stale failure cannot roll back a newer value',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = _ControlledSecureStorage(<bool>[false, true]);
      final controller = MangaReaderPreferencesController(storage);
      await controller.load();

      final first = controller.setPageGap(18);
      final second = controller.setPageGap(24);
      expect(controller.state.pageGap, 24);

      await Future.wait(<Future<void>>[first, second]);
      expect(controller.state.pageGap, 24);
      expect(storage.maximumConcurrentWrites, 1);

      final restored = MangaReaderPreferencesController(
        const FlutterSecureStorage(),
      );
      await restored.load();
      expect(restored.state.pageGap, 24);
    },
  );
}

class _ControlledSecureStorage extends FlutterSecureStorage {
  _ControlledSecureStorage(this._writeResults);

  final List<bool> _writeResults;
  var _activeWrites = 0;
  var maximumConcurrentWrites = 0;

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
    _activeWrites++;
    if (_activeWrites > maximumConcurrentWrites) {
      maximumConcurrentWrites = _activeWrites;
    }
    try {
      await Future<void>.delayed(Duration.zero);
      final succeeds = _writeResults.isEmpty ? true : _writeResults.removeAt(0);
      if (!succeeds) throw StateError('Protected storage rejected the write.');
      await super.write(key: key, value: value);
    } finally {
      _activeWrites--;
    }
  }
}

class _GatedSecureStorage extends FlutterSecureStorage {
  _GatedSecureStorage(
    this.gatedKey, {
    this.failedWriteKey,
    this.failedDeleteKey,
  });

  final String gatedKey;
  final String? failedWriteKey;
  final String? failedDeleteKey;
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
    if (key == gatedKey && !writeStarted.isCompleted) {
      writeStarted.complete();
      await releaseWrite.future;
    }
    if (key == failedWriteKey) throw StateError('Write denied');
    await super.write(key: key, value: value);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failedDeleteKey) throw StateError('Delete denied');
    await super.delete(key: key);
  }
}
