import 'package:flutter/foundation.dart';

/// Storage areas whose roots are owned and resolved by TetoTV.
///
/// A local reader page carries only a validated relative path. Presentation
/// code must resolve that path through the matching app-owned storage service;
/// it must never concatenate it with an arbitrary caller-provided directory.
enum MangaLocalStorageArea { downloadedPages, extractedArchive }

/// A page resource which is safe to pass through the in-process reader route.
///
/// Implementations intentionally expose no serialization API. In particular,
/// authentication headers on remote pages are runtime capabilities and must
/// not be copied into SQLite, diagnostics, navigation URLs, or party state.
@immutable
sealed class MangaPageResource {
  const MangaPageResource();
}

/// A remote image loaded over an authenticated or unauthenticated HTTPS URL.
@immutable
final class MangaRemotePageResource extends MangaPageResource {
  MangaRemotePageResource({
    required this.uri,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(headers) {
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Manga pages require an HTTPS URL without credentials or fragments.',
      );
    }
    if (uri.toString().length > 4096) {
      throw ArgumentError.value(uri, 'uri', 'URL is too long.');
    }
    if (headers.length > 32) {
      throw ArgumentError.value(headers, 'headers', 'Too many HTTP headers.');
    }
    for (final header in headers.entries) {
      if (!_headerName.hasMatch(header.key) ||
          header.value.length > 8192 ||
          header.value.contains(RegExp(r'[\r\n\u0000]'))) {
        throw ArgumentError.value(
          header.key,
          'headers',
          'Contains an invalid HTTP header.',
        );
      }
    }
  }

  static final RegExp _headerName = RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]+$');

  final Uri uri;

  /// Ephemeral request headers retained only for this in-memory reader request.
  final Map<String, String> headers;

  @override
  String toString() => 'MangaRemotePageResource($uri, headers: <redacted>)';
}

/// A page inside a storage area controlled by TetoTV.
///
/// Only a safe, normalized relative path is accepted. The type is deliberately
/// distinct from [MangaRemotePageResource], so UI code cannot accidentally
/// interpret untrusted catalog text as a local file URI.
@immutable
final class MangaTrustedLocalPageResource extends MangaPageResource {
  MangaTrustedLocalPageResource({
    required this.area,
    required String relativePath,
  }) : relativePath = _validateRelativePath(relativePath);

  final MangaLocalStorageArea area;
  final String relativePath;

  static String _validateRelativePath(String value) {
    if (value.isEmpty || value.length > 1024 || value != value.trim()) {
      throw ArgumentError.value(value, 'relativePath', 'Invalid local path.');
    }
    if (value.contains('\\') ||
        value.startsWith('/') ||
        value.startsWith('~') ||
        value.contains(RegExp(r'[\u0000-\u001f]'))) {
      throw ArgumentError.value(
        value,
        'relativePath',
        'Local page paths must be normalized relative paths.',
      );
    }
    final segments = value.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains(':'),
    )) {
      throw ArgumentError.value(
        value,
        'relativePath',
        'Local page paths cannot escape app-owned storage.',
      );
    }
    return value;
  }

  @override
  String toString() =>
      'MangaTrustedLocalPageResource(${area.name}, $relativePath)';
}

/// One page in logical reading order.
@immutable
class MangaReaderPage {
  MangaReaderPage({
    required String id,
    required this.index,
    required this.resource,
    this.pixelWidth,
    this.pixelHeight,
    this.isCover = false,
  }) : id = _requiredBoundedLabel(id, 'id', maxLength: 512) {
    if (index < 0 || index >= 1000) {
      throw ArgumentError.value(index, 'index', 'Page index is out of range.');
    }
    if ((pixelWidth == null) != (pixelHeight == null)) {
      throw ArgumentError(
        'pixelWidth and pixelHeight must either both be set or both be null.',
      );
    }
    if (pixelWidth case final width? when width <= 0 || width > 100000) {
      throw ArgumentError.value(width, 'pixelWidth', 'Invalid page width.');
    }
    if (pixelHeight case final height? when height <= 0 || height > 100000) {
      throw ArgumentError.value(height, 'pixelHeight', 'Invalid page height.');
    }
  }

  final String id;
  final int index;
  final MangaPageResource resource;
  final int? pixelWidth;
  final int? pixelHeight;
  final bool isCover;

  double? get aspectRatio {
    final width = pixelWidth;
    final height = pixelHeight;
    return width == null || height == null ? null : width / height;
  }

  bool isWide({double minimumAspectRatio = 1.15}) {
    final ratio = aspectRatio;
    return ratio != null && ratio >= minimumAspectRatio;
  }
}

/// Typed, in-memory request used to open one manga chapter.
@immutable
class MangaReaderRequest {
  MangaReaderRequest({
    required String sourceId,
    required String publicationId,
    required String chapterId,
    required String seriesTitle,
    required String chapterTitle,
    required Iterable<MangaReaderPage> pages,
    this.chapterNumber,
    this.initialPageIndex = 0,
  }) : sourceId = _requiredBoundedLabel(sourceId, 'sourceId'),
       publicationId = _requiredBoundedLabel(publicationId, 'publicationId'),
       chapterId = _requiredBoundedLabel(chapterId, 'chapterId'),
       seriesTitle = _requiredBoundedLabel(
         seriesTitle,
         'seriesTitle',
         maxLength: 512,
       ),
       chapterTitle = _requiredBoundedLabel(
         chapterTitle,
         'chapterTitle',
         maxLength: 512,
       ),
       pages = List<MangaReaderPage>.unmodifiable(pages) {
    if (this.pages.isEmpty || this.pages.length > 1000) {
      throw ArgumentError.value(
        this.pages.length,
        'pages',
        'A chapter must contain between 1 and 1000 pages.',
      );
    }
    final pageIds = <String>{};
    for (var index = 0; index < this.pages.length; index += 1) {
      final page = this.pages[index];
      if (page.index != index) {
        throw ArgumentError.value(
          page.index,
          'pages',
          'Page indexes must be contiguous and match reading order.',
        );
      }
      if (!pageIds.add(page.id)) {
        throw ArgumentError.value(page.id, 'pages', 'Page IDs must be unique.');
      }
    }
    if (initialPageIndex < 0 || initialPageIndex >= this.pages.length) {
      throw ArgumentError.value(
        initialPageIndex,
        'initialPageIndex',
        'Initial page is outside the chapter.',
      );
    }
    if (chapterNumber case final value?
        when !value.isFinite || value <= 0 || value > 100000) {
      throw ArgumentError.value(
        value,
        'chapterNumber',
        'Chapter number is out of range.',
      );
    }
  }

  final String sourceId;
  final String publicationId;
  final String chapterId;
  final String seriesTitle;
  final String chapterTitle;
  final double? chapterNumber;
  final List<MangaReaderPage> pages;
  final int initialPageIndex;

  @override
  String toString() =>
      'MangaReaderRequest($seriesTitle, $chapterTitle, '
      '${pages.length} pages)';
}

String _requiredBoundedLabel(
  String value,
  String field, {
  int maxLength = 256,
}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty ||
      trimmed.length > maxLength ||
      trimmed.contains(RegExp(r'[\u0000-\u001f]'))) {
    throw ArgumentError.value(value, field, 'Invalid label.');
  }
  return trimmed;
}
