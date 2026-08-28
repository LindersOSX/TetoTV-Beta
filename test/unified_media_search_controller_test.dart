import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/local_media/application/local_media_controller.dart';
import 'package:anime_tv/features/local_media/application/plex_controller.dart';
import 'package:anime_tv/features/local_media/application/unified_media_search_controller.dart';
import 'package:anime_tv/features/local_media/data/jellyfin_client.dart';
import 'package:anime_tv/features/local_media/data/plex_client.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'combines device and available server results when one server fails',
    () async {
      final local = _SearchLocalMediaController(
        results: const [
          JellyfinMediaItem(
            id: 'jellyfin-movie-1234',
            name: 'Cowboy Bebop Movie',
            type: 'Movie',
          ),
        ],
      );
      final plex = _SearchPlexController(error: const PlexException('offline'));
      addTearDown(local.dispose);
      addTearDown(plex.dispose);
      final controller = UnifiedMediaSearchController(
        localMedia: local,
        plex: plex,
        recentDocument: () => LocalMediaDocument.fromMap(const {
          'uri': 'content://usb.provider/videos/cowboy-bebop.mkv',
          'name': 'Cowboy Bebop Episode 1.mkv',
          'persistedReadPermission': true,
        }),
        hasJellyfin: () => true,
        hasPlex: () => true,
      );
      addTearDown(controller.dispose);

      await controller.search('cowboy');

      expect(controller.state.busy, isFalse);
      expect(controller.state.results.map((item) => item.origin), [
        UnifiedMediaOrigin.device,
        UnifiedMediaOrigin.jellyfin,
      ]);
      expect(controller.state.message, contains('Plex was unavailable'));
      expect(local.queries, ['cowboy']);
      expect(plex.queries, ['cowboy']);
    },
  );

  test('validates short searches without contacting either server', () async {
    final local = _SearchLocalMediaController();
    final plex = _SearchPlexController();
    addTearDown(local.dispose);
    addTearDown(plex.dispose);
    final controller = UnifiedMediaSearchController(
      localMedia: local,
      plex: plex,
      recentDocument: () => null,
      hasJellyfin: () => true,
      hasPlex: () => true,
    );
    addTearDown(controller.dispose);

    await controller.search('a');

    expect(controller.state.message, contains('at least two'));
    expect(local.queries, isEmpty);
    expect(plex.queries, isEmpty);
  });

  test('reports a useful empty state before a server is connected', () async {
    final local = _SearchLocalMediaController();
    final plex = _SearchPlexController();
    addTearDown(local.dispose);
    addTearDown(plex.dispose);
    final controller = UnifiedMediaSearchController(
      localMedia: local,
      plex: plex,
      recentDocument: () => null,
      hasJellyfin: () => false,
      hasPlex: () => false,
    );
    addTearDown(controller.dispose);

    await controller.search('bebop');

    expect(controller.state.results, isEmpty);
    expect(controller.state.message, contains('Connect Jellyfin or Plex'));
  });
}

class _SearchLocalMediaController extends LocalMediaController {
  _SearchLocalMediaController({this.results = const []})
    : super(
        const FlutterSecureStorage(),
        JellyfinClient(),
        AndroidTvBridge.instance,
      );

  final List<JellyfinMediaItem> results;
  final queries = <String>[];

  @override
  Future<List<JellyfinMediaItem>> search(String query) async {
    queries.add(query);
    return results;
  }
}

class _SearchPlexController extends PlexController {
  _SearchPlexController({this.error})
    : super(const FlutterSecureStorage(), PlexClient());

  final Object? error;
  final queries = <String>[];

  @override
  Future<List<PlexMediaItem>> search(String query) async {
    queries.add(query);
    if (error case final value?) throw value;
    return const [];
  }
}
