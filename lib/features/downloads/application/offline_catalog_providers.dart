import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/application/offline_catalog_snapshot_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final offlineCatalogSnapshotServiceProvider =
    Provider<OfflineCatalogSnapshotService>((ref) {
      return OfflineCatalogSnapshotService(
        repository: ref.watch(downloadRepositoryProvider),
        storage: ref.watch(offlineDownloadStorageProvider),
      );
    });

final offlineCatalogSnapshotsProvider =
    FutureProvider<List<OfflineCatalogSnapshot>>(
      (ref) => ref.watch(offlineCatalogSnapshotServiceProvider).list(),
    );
