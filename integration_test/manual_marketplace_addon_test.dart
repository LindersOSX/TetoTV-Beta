import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _repositoryUrl = String.fromEnvironment('MANUAL_MARKETPLACE_URL');
const _addonId = String.fromEnvironment('MANUAL_ADDON_ID');
const _animeTitle = String.fromEnvironment(
  'MANUAL_ADDON_TEST_TITLE',
  defaultValue: 'One Piece',
);
const _episode = int.fromEnvironment(
  'MANUAL_ADDON_TEST_EPISODE',
  defaultValue: 1,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a manually supplied marketplace addon installs and discovers a stream',
    (tester) async {
      final store = AddonStore(TetoTvDatabase.instance);
      final client = MarketplaceClient(store);
      final repository = AddonRepository(
        url: _repositoryUrl,
        updatedAt: DateTime.now(),
      );
      final catalog = await client.catalog(repository, refresh: true);
      final summary = catalog.singleWhere((addon) => addon.id == _addonId);
      final installed = await client.downloadAddon(summary);

      final streams = await SeanimeJavascriptProvider(installed).streams(
        const EpisodeReference(
          anilistMediaId: 21,
          malMediaId: 21,
          title: _animeTitle,
          episode: _episode,
        ),
      );

      expect(installed.payload, contains('class Provider'));
      expect(streams, isNotEmpty);
      expect(streams.every((stream) => stream.uri.scheme == 'https'), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _repositoryUrl.isEmpty || _addonId.isEmpty,
  );
}
