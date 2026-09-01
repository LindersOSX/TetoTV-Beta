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

    await controller.reset();
    final restored = MangaReaderPreferencesController(storage);
    await restored.load();

    expect(restored.state, isA<MangaReaderPreferences>());
    expect(restored.state.mode, MangaReadingMode.paged);
    expect(restored.state.pageGap, 12);
    expect(restored.state.loaded, isTrue);
  });

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
