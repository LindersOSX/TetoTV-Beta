import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/local_media/application/local_media_controller.dart';
import 'package:anime_tv/features/local_media/application/plex_controller.dart';
import 'package:anime_tv/features/local_media/application/unified_media_search_controller.dart';
import 'package:anime_tv/features/local_media/data/jellyfin_client.dart';
import 'package:anime_tv/features/local_media/data/plex_client.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:anime_tv/features/local_media/presentation/local_media_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'Modern Your Media traverses off-screen server rows and restores from rail',
    (tester) async {
      await _pumpMedia(
        tester,
        mode: InterfaceMode.television,
        localState: _connectedJellyfinState(itemCount: 12),
        plexState: _connectedPlexState(libraryCount: 12),
        searchState: _mediaSearchState(resultCount: 8),
      );

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.unified-search',
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.search-result.0',
      );

      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.search-result.0',
        reason: 'an immediate held repeat must not skip a media section',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 110)),
      );
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.search-result.1',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);

      for (var index = 2; index < 8; index++) {
        await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'local-media.search-result.$index',
        );
      }
      await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.choose-video',
      );
      await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.jellyfin.refresh',
      );

      for (var index = 0; index < 12; index++) {
        await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'local-media.jellyfin.item.$index',
        );
      }
      _expectVisible(
        tester,
        find.byKey(const ValueKey('jellyfin-item-item-11')),
      );

      await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.plex.refresh',
      );
      for (var index = 0; index < 12; index++) {
        await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'local-media.plex.item.$index',
        );
      }
      _expectVisible(
        tester,
        find.byKey(const ValueKey('plex-library-library-11')),
      );
      _expectFocusedControlVisible(tester);

      await _pressAndSettle(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'top-level.active-navigation',
      );
      await _pressAndSettle(tester, LogicalKeyboardKey.arrowRight);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.plex.item.11',
        reason: 'RIGHT from the active rail restores the exact media control',
      );
      _expectFocusedControlVisible(tester);

      final screenContext = tester.element(find.byType(LocalMediaScreen));
      unawaited(
        Navigator.of(screenContext).push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Temporary route')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Temporary route'))).pop();
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.plex.item.11',
        reason: 'returning to Your Media retains its last D-pad target',
      );
      _expectFocusedControlVisible(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Classic Your Media scrolls through every connection control', (
    tester,
  ) async {
    await _pumpMedia(
      tester,
      mode: InterfaceMode.phone,
      localState: const LocalMediaState(loaded: true),
    );

    expect(find.text('Back'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.unified-search',
    );
    await _pressAndSettle(tester, LogicalKeyboardKey.arrowLeft);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'local-media.back');
    await _pressAndSettle(tester, LogicalKeyboardKey.arrowRight);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.unified-search',
    );

    for (var step = 0; step < 8; step++) {
      await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.plex.connect',
    );
    _expectFocusedControlVisible(tester);

    for (var step = 0; step < 8; step++) {
      await _pressAndSettle(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.unified-search',
    );
    _expectFocusedControlVisible(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Search and server connection replacements restore a D-pad target',
    (tester) async {
      final harness = await _pumpMedia(
        tester,
        mode: InterfaceMode.television,
        localState: const LocalMediaState(loaded: true),
        nextSearchResults: _mediaSearchState(resultCount: 1).results,
      );

      _focusNode('local-media.search-action').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.search-result.0',
        reason: 'submitting Search should land on the first new result',
      );

      _focusNode('local-media.jellyfin.connect').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(harness.local.state.connection, isNotNull);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.jellyfin.refresh',
        reason: 'the removed Jellyfin form must hand focus to Refresh',
      );

      for (var step = 0; step < 3; step++) {
        await _pressAndSettle(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.plex.connect',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(harness.plex.state.connection, isNotNull);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'local-media.plex.refresh',
        reason: 'the removed Plex form must hand focus to Refresh',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shrinking result and folder lists recovers nearby focus', (
    tester,
  ) async {
    final harness = await _pumpMedia(
      tester,
      mode: InterfaceMode.television,
      localState: _connectedJellyfinState(itemCount: 3),
      plexState: _connectedPlexState(libraryCount: 3),
      searchState: _mediaSearchState(resultCount: 3),
    );

    _focusNode('local-media.search-result.2').requestFocus();
    await tester.pump();
    harness.search.replace(const UnifiedMediaSearchState(query: 'new'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.search-action',
    );

    _focusNode('local-media.jellyfin.item.2').requestFocus();
    await tester.pump();
    harness.local.replace(
      harness.local.state.copyWith(
        items: const [],
        totalCount: 0,
        nextStartIndex: 0,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.jellyfin.refresh',
    );

    _focusNode('local-media.plex.item.2').requestFocus();
    await tester.pump();
    harness.plex.replace(
      harness.plex.state.copyWith(
        libraries: const [],
        totalCount: 0,
        nextOffset: 0,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'local-media.plex.refresh',
    );
    expect(tester.takeException(), isNull);
  });
}

Future<
  ({
    _NavigationLocalMediaController local,
    _NavigationPlexController plex,
    _NavigationSearchController search,
  })
>
_pumpMedia(
  WidgetTester tester, {
  required InterfaceMode mode,
  required LocalMediaState localState,
  PlexState plexState = const PlexState(loaded: true),
  UnifiedMediaSearchState searchState = const UnifiedMediaSearchState(),
  List<UnifiedMediaSearchItem> nextSearchResults = const [],
}) async {
  tester.view.physicalSize = const Size(960, 540);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  const storage = FlutterSecureStorage();
  final local = _NavigationLocalMediaController(storage, localState);
  final plex = _NavigationPlexController(storage, plexState);
  final search = _NavigationSearchController(
    local,
    plex,
    searchState,
    nextResults: nextSearchResults,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localMediaControllerProvider.overrideWith((_) => local),
        plexControllerProvider.overrideWith((_) => plex),
        unifiedMediaSearchControllerProvider.overrideWith((_) => search),
        settingsPreferencesProvider.overrideWith(
          (_) => _NavigationSettingsController(storage, mode),
        ),
      ],
      child: const MaterialApp(home: LocalMediaScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return (local: local, plex: plex, search: search);
}

Future<void> _pressAndSettle(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void _expectVisible(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  expect(
    rect.overlaps(Offset.zero & tester.view.physicalSize),
    isTrue,
    reason: 'The selected media row must be revealed on the 960x540 canvas',
  );
}

void _expectFocusedControlVisible(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  expect(context, isNotNull);
  final box = context!.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  expect(rect.overlaps(Offset.zero & tester.view.physicalSize), isTrue);
}

FocusNode _focusNode(String debugLabel) => FocusManager
    .instance
    .rootScope
    .descendants
    .firstWhere((node) => node.debugLabel == debugLabel);

LocalMediaState _connectedJellyfinState({required int itemCount}) =>
    LocalMediaState(
      loaded: true,
      connection: JellyfinConnection(
        baseUri: Uri.parse('https://jellyfin.example.com'),
        serverName: 'Test Jellyfin',
        serverVersion: '10.10',
        userId: 'user-id',
        username: 'viewer',
        accessToken: 'not-a-real-token',
        deviceId: 'test-device',
      ),
      items: [
        for (var index = 0; index < itemCount; index++)
          JellyfinMediaItem(
            id: 'item-$index',
            name: 'Library item $index',
            type: 'Movie',
          ),
      ],
      totalCount: itemCount,
      nextStartIndex: itemCount,
    );

PlexState _connectedPlexState({required int libraryCount}) => PlexState(
  loaded: true,
  connection: PlexConnection(
    baseUri: Uri.parse('https://plex.example.com'),
    accessToken: 'not-a-real-token',
    clientIdentifier: 'test-client',
    serverName: 'Test Plex',
    serverVersion: '1.41',
  ),
  libraries: [
    for (var index = 0; index < libraryCount; index++)
      PlexLibrary(
        key: 'library-$index',
        title: 'Plex library $index',
        type: index.isEven ? PlexMediaType.movie : PlexMediaType.show,
      ),
  ],
  totalCount: libraryCount,
  nextOffset: libraryCount,
);

UnifiedMediaSearchState _mediaSearchState({required int resultCount}) =>
    UnifiedMediaSearchState(
      query: 'library',
      results: [
        for (var index = 0; index < resultCount; index++)
          UnifiedMediaSearchItem.device(
            LocalMediaDocument(
              uri: Uri.parse('content://test/search-$index'),
              name: 'Search result $index',
            ),
          ),
      ],
    );

class _NavigationLocalMediaController extends LocalMediaController {
  _NavigationLocalMediaController(
    FlutterSecureStorage storage,
    LocalMediaState initialState,
  ) : super(storage, JellyfinClient(), AndroidTvBridge.instance) {
    state = initialState;
  }

  @override
  Future<void> load() async {}

  @override
  Uri? imageUri(JellyfinMediaItem item) => null;

  void replace(LocalMediaState value) => state = value;

  @override
  Future<void> connect({
    required String address,
    required String username,
    required String password,
  }) async {
    state = LocalMediaState(
      loaded: true,
      connection: JellyfinConnection(
        baseUri: Uri.parse('https://jellyfin.example.com'),
        serverName: 'Test Jellyfin',
        serverVersion: '10.10',
        userId: 'user-id',
        username: 'viewer',
        accessToken: 'not-a-real-token',
        deviceId: 'test-device',
      ),
    );
  }
}

class _NavigationPlexController extends PlexController {
  // The second super-constructor argument is supplied by this test fixture.
  // ignore: use_super_parameters
  _NavigationPlexController(
    FlutterSecureStorage storage,
    PlexState initialState,
  ) : super(storage, PlexClient()) {
    state = initialState;
  }

  @override
  Future<void> load() async {}

  @override
  Uri? libraryImageUri(PlexLibrary library) => null;

  @override
  Uri? imageUri(PlexMediaItem item) => null;

  void replace(PlexState value) => state = value;

  @override
  Future<void> connect({required String address, required String token}) async {
    state = PlexState(
      loaded: true,
      connection: PlexConnection(
        baseUri: Uri.parse('https://plex.example.com'),
        accessToken: 'not-a-real-token',
        clientIdentifier: 'test-client',
        serverName: 'Test Plex',
        serverVersion: '1.41',
      ),
    );
  }
}

class _NavigationSearchController extends UnifiedMediaSearchController {
  _NavigationSearchController(
    LocalMediaController local,
    PlexController plex,
    UnifiedMediaSearchState initialState, {
    this.nextResults = const [],
  }) : super(
         localMedia: local,
         plex: plex,
         recentDocument: () => null,
         hasJellyfin: () => local.state.connection != null,
         hasPlex: () => plex.state.connection != null,
       ) {
    state = initialState;
  }

  final List<UnifiedMediaSearchItem> nextResults;

  void replace(UnifiedMediaSearchState value) => state = value;

  @override
  Future<void> search(String rawQuery) async {
    state = const UnifiedMediaSearchState(query: 'query', busy: true);
    await Future<void>.delayed(Duration.zero);
    state = UnifiedMediaSearchState(query: 'query', results: nextResults);
  }
}

class _NavigationSettingsController extends SettingsPreferencesController {
  _NavigationSettingsController(super.storage, InterfaceMode mode) {
    state = SettingsPreferences(loaded: true, interfaceMode: mode);
  }

  @override
  Future<void> load() async {}
}
