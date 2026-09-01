import 'dart:io';
import 'dart:isolate';

/// Hard bounds applied before an untrusted manga image reaches Flutter's
/// decoder. The pixel-area cap is the important memory bound: a seemingly
/// small encoded image can otherwise request hundreds of megabytes of RGBA
/// memory on a phone or TV.
const int maximumMangaImageWidth = 8192;
const int maximumMangaImageHeight = 16384;
const int maximumMangaImagePixels = 32 * 1024 * 1024;

enum MangaArchiveImageType {
  jpeg(extension: '.jpg', mimeType: 'image/jpeg'),
  png(extension: '.png', mimeType: 'image/png'),
  webp(extension: '.webp', mimeType: 'image/webp'),
  gif(extension: '.gif', mimeType: 'image/gif');

  const MangaArchiveImageType({
    required this.extension,
    required this.mimeType,
  });

  final String extension;
  final String mimeType;
}

enum MangaImageValidationFailure { unsupported, malformed, dimensionsExceeded }

class MangaImageValidationException implements Exception {
  const MangaImageValidationException(this.failure, this.message);

  final MangaImageValidationFailure failure;
  final String message;

  @override
  String toString() => message;
}

class MangaImageInfo {
  const MangaImageInfo({
    required this.type,
    required this.width,
    required this.height,
  });

  final MangaArchiveImageType type;
  final int width;
  final int height;
}

/// Inspects an app-owned page without reading or parsing it on Flutter's UI
/// isolate. Acquisition already validates new files before persistence; this
/// second boundary also protects readers opening data created by older builds.
Future<MangaImageInfo> inspectMangaImageFile(File file) {
  final filePath = file.path;
  return Isolate.run(
    () => inspectMangaImage(File(filePath).readAsBytesSync()),
    debugName: 'tetotv-manga-image-header',
  );
}

/// Reads only image container headers; it never invokes an image codec.
///
/// JPEG, PNG, GIF, and the three WebP bitstream variants are supported. AVIF
/// is deliberately not accepted because determining its presentation size
/// safely requires a full ISO-BMFF parser, which should not run on untrusted
/// catalog bytes in the reader process.
MangaImageInfo inspectMangaImage(
  List<int> bytes, {
  int maximumWidth = maximumMangaImageWidth,
  int maximumHeight = maximumMangaImageHeight,
  int maximumPixels = maximumMangaImagePixels,
}) {
  if (maximumWidth <= 0 || maximumHeight <= 0 || maximumPixels <= 0) {
    throw ArgumentError('Manga image limits must be positive.');
  }
  final type = detectMangaImageType(bytes);
  if (type == null) {
    throw const MangaImageValidationException(
      MangaImageValidationFailure.unsupported,
      'The manga page is not a supported image.',
    );
  }
  final dimensions = switch (type) {
    MangaArchiveImageType.jpeg => _jpegDimensions(bytes),
    MangaArchiveImageType.png => _pngDimensions(bytes),
    MangaArchiveImageType.webp => _webpDimensions(bytes),
    MangaArchiveImageType.gif => _gifDimensions(bytes),
  };
  final width = dimensions.$1;
  final height = dimensions.$2;
  if (width <= 0 || height <= 0) {
    throw const MangaImageValidationException(
      MangaImageValidationFailure.malformed,
      'The manga page has invalid image dimensions.',
    );
  }
  if (width > maximumWidth ||
      height > maximumHeight ||
      width > maximumPixels ~/ height) {
    throw const MangaImageValidationException(
      MangaImageValidationFailure.dimensionsExceeded,
      'The manga page dimensions exceed the safe decode limit.',
    );
  }
  return MangaImageInfo(type: type, width: width, height: height);
}

/// Detects a supported image container from trusted leading bytes.
///
/// This is only a type hint. Call [inspectMangaImage] before persistence or
/// decode so malformed headers and dimension bombs are rejected too.
MangaArchiveImageType? detectMangaImageType(List<int> bytes) {
  if (_matchesAt(bytes, 0, const <int>[0xff, 0xd8, 0xff])) {
    return MangaArchiveImageType.jpeg;
  }
  if (_matchesAt(bytes, 0, const <int>[
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ])) {
    return MangaArchiveImageType.png;
  }
  if (_matchesAt(bytes, 0, const <int>[0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      _matchesAt(bytes, 0, const <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
    return MangaArchiveImageType.gif;
  }
  if (_matchesAt(bytes, 0, const <int>[0x52, 0x49, 0x46, 0x46]) &&
      _matchesAt(bytes, 8, const <int>[0x57, 0x45, 0x42, 0x50])) {
    return MangaArchiveImageType.webp;
  }
  return null;
}

(int, int) _pngDimensions(List<int> bytes) {
  if (bytes.length < 24 ||
      _uint32BigEndian(bytes, 8) != 13 ||
      !_matchesAt(bytes, 12, const <int>[0x49, 0x48, 0x44, 0x52])) {
    throw const MangaImageValidationException(
      MangaImageValidationFailure.malformed,
      'The PNG page has a malformed IHDR header.',
    );
  }
  return (_uint32BigEndian(bytes, 16), _uint32BigEndian(bytes, 20));
}

(int, int) _gifDimensions(List<int> bytes) {
  if (bytes.length < 10) {
    throw const MangaImageValidationException(
      MangaImageValidationFailure.malformed,
      'The GIF page has a truncated logical screen descriptor.',
    );
  }
  return (_uint16LittleEndian(bytes, 6), _uint16LittleEndian(bytes, 8));
}

(int, int) _jpegDimensions(List<int> bytes) {
  var offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset] != 0xff) {
      throw const MangaImageValidationException(
        MangaImageValidationFailure.malformed,
        'The JPEG page has a malformed marker stream.',
      );
    }
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset += 1;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0x00) {
      throw const MangaImageValidationException(
        MangaImageValidationFailure.malformed,
        'The JPEG page has an invalid marker.',
      );
    }
    if (marker == 0xd8 ||
        marker == 0x01 ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (marker == 0xd9 || marker == 0xda) break;
    if (offset + 2 > bytes.length) break;
    final segmentLength = _uint16BigEndian(bytes, offset);
    if (segmentLength < 2 || offset + segmentLength > bytes.length) {
      throw const MangaImageValidationException(
        MangaImageValidationFailure.malformed,
        'The JPEG page has a truncated segment.',
      );
    }
    if (_jpegStartOfFrameMarkers.contains(marker)) {
      if (segmentLength < 7) {
        throw const MangaImageValidationException(
          MangaImageValidationFailure.malformed,
          'The JPEG page has a malformed frame header.',
        );
      }
      return (
        _uint16BigEndian(bytes, offset + 5),
        _uint16BigEndian(bytes, offset + 3),
      );
    }
    offset += segmentLength;
  }
  throw const MangaImageValidationException(
    MangaImageValidationFailure.malformed,
    'The JPEG page does not contain a supported frame header.',
  );
}

(int, int) _webpDimensions(List<int> bytes) {
  if (bytes.length < 20) {
    throw const MangaImageValidationException(
      MangaImageValidationFailure.malformed,
      'The WebP page is truncated.',
    );
  }
  final declaredRiffLength = _uint32LittleEndian(bytes, 4) + 8;
  if (declaredRiffLength < 20 || declaredRiffLength > bytes.length) {
    throw const MangaImageValidationException(
      MangaImageValidationFailure.malformed,
      'The WebP page has an invalid RIFF length.',
    );
  }
  var offset = 12;
  while (offset + 8 <= declaredRiffLength) {
    final chunkSize = _uint32LittleEndian(bytes, offset + 4);
    final dataOffset = offset + 8;
    if (chunkSize > declaredRiffLength - dataOffset) {
      throw const MangaImageValidationException(
        MangaImageValidationFailure.malformed,
        'The WebP page contains a truncated chunk.',
      );
    }
    if (_matchesAt(bytes, offset, const <int>[0x56, 0x50, 0x38, 0x58])) {
      if (chunkSize < 10) break;
      return (
        1 + _uint24LittleEndian(bytes, dataOffset + 4),
        1 + _uint24LittleEndian(bytes, dataOffset + 7),
      );
    }
    if (_matchesAt(bytes, offset, const <int>[0x56, 0x50, 0x38, 0x4c])) {
      if (chunkSize < 5 || bytes[dataOffset] != 0x2f) break;
      final b1 = bytes[dataOffset + 1];
      final b2 = bytes[dataOffset + 2];
      final b3 = bytes[dataOffset + 3];
      final b4 = bytes[dataOffset + 4];
      return (
        1 + b1 + ((b2 & 0x3f) << 8),
        1 + (b2 >> 6) + (b3 << 2) + ((b4 & 0x0f) << 10),
      );
    }
    if (_matchesAt(bytes, offset, const <int>[0x56, 0x50, 0x38, 0x20])) {
      if (chunkSize < 10 ||
          !_matchesAt(bytes, dataOffset + 3, const <int>[0x9d, 0x01, 0x2a])) {
        break;
      }
      return (
        _uint16LittleEndian(bytes, dataOffset + 6) & 0x3fff,
        _uint16LittleEndian(bytes, dataOffset + 8) & 0x3fff,
      );
    }
    final paddedSize = chunkSize + (chunkSize.isOdd ? 1 : 0);
    if (paddedSize > declaredRiffLength - dataOffset) break;
    offset = dataOffset + paddedSize;
  }
  throw const MangaImageValidationException(
    MangaImageValidationFailure.malformed,
    'The WebP page does not contain a supported image bitstream.',
  );
}

int _uint16BigEndian(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _uint16LittleEndian(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _uint24LittleEndian(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

int _uint32BigEndian(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _uint32LittleEndian(List<int> bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

bool _matchesAt(List<int> bytes, int offset, List<int> signature) {
  if (offset < 0 || bytes.length < offset + signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}

const Set<int> _jpegStartOfFrameMarkers = <int>{
  0xc0,
  0xc1,
  0xc2,
  0xc3,
  0xc5,
  0xc6,
  0xc7,
  0xc9,
  0xca,
  0xcb,
  0xcd,
  0xce,
  0xcf,
};
