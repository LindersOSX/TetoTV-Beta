import 'dart:io';

import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class MangaStorageRoots {
  const MangaStorageRoots({
    required this.downloadedPages,
    required this.extractedArchives,
  });

  final Directory downloadedPages;
  final Directory extractedArchives;

  Directory rootFor(MangaLocalStorageArea area) => switch (area) {
    MangaLocalStorageArea.downloadedPages => downloadedPages,
    MangaLocalStorageArea.extractedArchive => extractedArchives,
  };

  File resolvePage(MangaTrustedLocalPageResource resource) {
    final root = rootFor(resource.area).absolute;
    final candidate = File(
      path.normalize(
        path.joinAll(<String>[root.path, ...resource.relativePath.split('/')]),
      ),
    ).absolute;
    if (!path.isWithin(root.path, candidate.path)) {
      throw StateError('The manga page is outside TetoTV storage.');
    }
    return candidate;
  }
}

final mangaStorageRootsProvider = FutureProvider<MangaStorageRoots>((
  ref,
) async {
  final support = await getApplicationSupportDirectory();
  final temporary = await getTemporaryDirectory();
  final downloaded = Directory(
    path.join(support.path, 'manga', 'v1', 'downloaded-pages'),
  );
  final extracted = Directory(
    path.join(temporary.path, 'manga', 'v1', 'extracted-archives'),
  );
  await downloaded.create(recursive: true);
  await extracted.create(recursive: true);
  return MangaStorageRoots(
    downloadedPages: downloaded,
    extractedArchives: extracted,
  );
});
