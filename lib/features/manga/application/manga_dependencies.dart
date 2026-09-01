import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final mangaSourceCredentialStoreProvider = Provider<MangaSourceCredentialStore>(
  (ref) => MangaSourceCredentialStore(ref.watch(secureStorageProvider)),
);

final mangaCatalogClientProvider = Provider<MangaCatalogClient>(
  (ref) => MangaCatalogClient(
    credentials: ref.watch(mangaSourceCredentialStoreProvider),
  ),
);

final mangaStoreProvider = Provider<MangaStore>(
  (ref) =>
      MangaStore(credentials: ref.watch(mangaSourceCredentialStoreProvider)),
);
