import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

export 'package:anime_tv/features/manga/data/manga_image_safety.dart'
    show MangaArchiveImageType, detectMangaImageType;

const int maximumMangaArchivePages = 1000;
const int maximumMangaArchivePageBytes = 20 * 1024 * 1024;
const int maximumMangaArchiveUncompressedBytes = 512 * 1024 * 1024;
const int maximumMangaArchiveCompressionRatio = 100;

enum MangaArchiveFailureCode {
  missingArchive,
  unsupportedArchiveType,
  invalidArchive,
  unsafeEntryPath,
  symbolicLink,
  unsupportedEntry,
  tooManyPages,
  pageTooLarge,
  archiveTooLarge,
  suspiciousCompression,
  corruptEntry,
  invalidImage,
  unsafeImageDimensions,
  emptyArchive,
  stagingFailure,
  cancelled,
}

class MangaArchiveException implements Exception {
  const MangaArchiveException(this.code, this.message, {this.entryName});

  final MangaArchiveFailureCode code;
  final String message;
  final String? entryName;

  @override
  String toString() {
    final entry = entryName == null ? '' : ' ($entryName)';
    return 'MangaArchiveException: $message$entry';
  }
}

class MangaArchiveLimits {
  const MangaArchiveLimits({
    int maximumPages = maximumMangaArchivePages,
    int maximumPageBytes = maximumMangaArchivePageBytes,
    int maximumUncompressedBytes = maximumMangaArchiveUncompressedBytes,
    int maximumCompressionRatio = maximumMangaArchiveCompressionRatio,
    int maximumEntries = maximumMangaArchivePages * 2,
  }) : assert(maximumPages > 0),
       assert(maximumPageBytes > 0),
       assert(maximumUncompressedBytes > 0),
       assert(maximumCompressionRatio > 0),
       assert(maximumEntries > 0),
       maximumPages = maximumPages > maximumMangaArchivePages
           ? maximumMangaArchivePages
           : maximumPages,
       maximumPageBytes = maximumPageBytes > maximumMangaArchivePageBytes
           ? maximumMangaArchivePageBytes
           : maximumPageBytes,
       maximumUncompressedBytes =
           maximumUncompressedBytes > maximumMangaArchiveUncompressedBytes
           ? maximumMangaArchiveUncompressedBytes
           : maximumUncompressedBytes,
       maximumCompressionRatio =
           maximumCompressionRatio > maximumMangaArchiveCompressionRatio
           ? maximumMangaArchiveCompressionRatio
           : maximumCompressionRatio,
       maximumEntries = maximumEntries > maximumMangaArchivePages * 2
           ? maximumMangaArchivePages * 2
           : maximumEntries;

  final int maximumPages;
  final int maximumPageBytes;
  final int maximumUncompressedBytes;
  final int maximumCompressionRatio;

  /// Includes directory entries. This prevents archives made primarily of
  /// metadata entries from bypassing the page-count limit.
  final int maximumEntries;
}

class MangaArchivePage {
  const MangaArchivePage({
    required this.index,
    required this.originalPath,
    required this.file,
    required this.imageType,
    required this.byteLength,
  });

  final int index;
  final String originalPath;
  final File file;
  final MangaArchiveImageType imageType;
  final int byteLength;

  String get mimeType => imageType.mimeType;
}

class MangaArchiveExtraction {
  const MangaArchiveExtraction({
    required this.directory,
    required this.pages,
    required this.totalUncompressedBytes,
  });

  final Directory directory;
  final List<MangaArchivePage> pages;
  final int totalUncompressedBytes;
}

/// Validates and extracts a CBZ/ZIP into an isolated child of a trusted
/// staging directory.
///
/// Original archive paths are never used as output paths. Every page is
/// copied to a generated `.part` file and atomically renamed only after its
/// byte count, CRC, extension, container, and decoded dimensions have been
/// verified. ZIP directory parsing and decompression always run outside the
/// Flutter UI isolate.
class MangaArchiveService {
  const MangaArchiveService({
    this.limits = const MangaArchiveLimits(),
    this.workerStartDelay = Duration.zero,
  });

  final MangaArchiveLimits limits;

  /// Makes worker scheduling observable in deterministic non-blocking tests.
  /// Production callers should leave this at zero.
  final Duration workerStartDelay;

  Future<MangaArchiveExtraction> extract({
    required File archiveFile,
    required Directory stagingDirectory,
    Future<void>? cancellation,
  }) async {
    if (!path.isAbsolute(stagingDirectory.path)) {
      throw ArgumentError.value(
        stagingDirectory.path,
        'stagingDirectory',
        'The trusted staging directory must use an absolute path.',
      );
    }

    final archiveExtension = path.extension(archiveFile.path).toLowerCase();
    if (archiveExtension != '.cbz' && archiveExtension != '.zip') {
      throw const MangaArchiveException(
        MangaArchiveFailureCode.unsupportedArchiveType,
        'Only ZIP and CBZ archives are supported.',
      );
    }
    if (!await archiveFile.exists()) {
      throw const MangaArchiveException(
        MangaArchiveFailureCode.missingArchive,
        'The manga archive does not exist.',
      );
    }
    if (workerStartDelay.isNegative ||
        workerStartDelay > const Duration(seconds: 5)) {
      throw ArgumentError.value(
        workerStartDelay,
        'workerStartDelay',
        'Worker delay must be between zero and five seconds.',
      );
    }

    await stagingDirectory.create(recursive: true);
    final operationDirectory = await stagingDirectory.createTemp('manga-cbz-');
    final receivePort = ReceivePort();
    final completer = Completer<MangaArchiveExtraction>();
    Isolate? worker;
    var settled = false;
    var cancellationRequested = false;

    Future<void> fail(MangaArchiveException error) async {
      if (settled) return;
      settled = true;
      worker?.kill(priority: Isolate.immediate);
      await _deleteOperationDirectory(operationDirectory);
      if (!completer.isCompleted) completer.completeError(error);
    }

    final subscription = receivePort.listen((Object? message) async {
      if (settled) return;
      if (message is Map) {
        final result = Map<String, Object?>.from(message);
        if (result['ok'] == true) {
          settled = true;
          final pageMessages = (result['pages'] as List<Object?>?) ?? const [];
          final pages = <MangaArchivePage>[
            for (final raw in pageMessages)
              _pageFromWorkerMessage(Map<String, Object?>.from(raw! as Map)),
          ];
          completer.complete(
            MangaArchiveExtraction(
              directory: operationDirectory,
              pages: List<MangaArchivePage>.unmodifiable(pages),
              totalUncompressedBytes: result['totalUncompressedBytes']! as int,
            ),
          );
          return;
        }
        await fail(_exceptionFromWorkerMessage(result));
        return;
      }
      if (message is List && message.isNotEmpty) {
        await fail(
          const MangaArchiveException(
            MangaArchiveFailureCode.invalidArchive,
            'The ZIP/CBZ worker stopped unexpectedly.',
          ),
        );
        return;
      }
      if (message == null) {
        // Isolate exit notifications share this port. A successful worker uses
        // Isolate.exit with its result first, so null without a result is fatal.
        scheduleMicrotask(() {
          if (!settled) {
            unawaited(
              fail(
                const MangaArchiveException(
                  MangaArchiveFailureCode.invalidArchive,
                  'The ZIP/CBZ worker stopped before finishing.',
                ),
              ),
            );
          }
        });
      }
    });

    if (cancellation != null) {
      unawaited(
        cancellation.then((_) {
          cancellationRequested = true;
          if (!settled) {
            unawaited(
              fail(
                const MangaArchiveException(
                  MangaArchiveFailureCode.cancelled,
                  'The manga archive extraction was cancelled.',
                ),
              ),
            );
          }
        }),
      );
    }

    try {
      worker = await Isolate.spawn<Map<String, Object?>>(
        _mangaArchiveWorker,
        <String, Object?>{
          'sendPort': receivePort.sendPort,
          'archivePath': archiveFile.path,
          'operationPath': operationDirectory.path,
          'limits': _limitsToMessage(limits),
          'delayMilliseconds': workerStartDelay.inMilliseconds,
        },
        onError: receivePort.sendPort,
        onExit: receivePort.sendPort,
        errorsAreFatal: true,
        debugName: 'tetotv-manga-cbz',
      );
      if (cancellationRequested && !settled) {
        await fail(
          const MangaArchiveException(
            MangaArchiveFailureCode.cancelled,
            'The manga archive extraction was cancelled.',
          ),
        );
      }
      return await completer.future;
    } on MangaArchiveException {
      rethrow;
    } catch (_) {
      await fail(
        const MangaArchiveException(
          MangaArchiveFailureCode.stagingFailure,
          'The archive worker could not be started.',
        ),
      );
      return await completer.future;
    } finally {
      await subscription.cancel();
      receivePort.close();
    }
  }
}

void _mangaArchiveWorker(Map<String, Object?> message) {
  final sendPort = message['sendPort']! as SendPort;
  final archivePath = message['archivePath']! as String;
  final operationPath = message['operationPath']! as String;
  final limits = _limitsFromMessage(
    Map<String, Object?>.from(message['limits']! as Map),
  );
  final delayMilliseconds = message['delayMilliseconds']! as int;
  try {
    if (delayMilliseconds > 0) {
      sleep(Duration(milliseconds: delayMilliseconds));
    }
    final result = _extractArchiveInWorker(
      archiveFile: File(archivePath),
      operationDirectory: Directory(operationPath),
      limits: limits,
    );
    Isolate.exit(sendPort, result);
  } on MangaArchiveException catch (error) {
    _deleteOperationDirectorySync(Directory(operationPath));
    Isolate.exit(sendPort, _exceptionToWorkerMessage(error));
  } on FileSystemException {
    _deleteOperationDirectorySync(Directory(operationPath));
    Isolate.exit(
      sendPort,
      _exceptionToWorkerMessage(
        const MangaArchiveException(
          MangaArchiveFailureCode.stagingFailure,
          'The archive could not be copied into protected staging.',
        ),
      ),
    );
  } on ArchiveException {
    _deleteOperationDirectorySync(Directory(operationPath));
    Isolate.exit(
      sendPort,
      _exceptionToWorkerMessage(
        const MangaArchiveException(
          MangaArchiveFailureCode.invalidArchive,
          'The ZIP/CBZ archive is corrupt or unsupported.',
        ),
      ),
    );
  } catch (_) {
    _deleteOperationDirectorySync(Directory(operationPath));
    Isolate.exit(
      sendPort,
      _exceptionToWorkerMessage(
        const MangaArchiveException(
          MangaArchiveFailureCode.invalidArchive,
          'The ZIP/CBZ archive is corrupt or unsupported.',
        ),
      ),
    );
  }
}

Map<String, Object?> _extractArchiveInWorker({
  required File archiveFile,
  required Directory operationDirectory,
  required MangaArchiveLimits limits,
}) {
  _validateZipSignatureSync(archiveFile);
  InputFileStream? input;
  try {
    input = InputFileStream(archiveFile.path);
    final archiveLength = input.length;
    final directory = ZipDirectory()..read(input);
    final entries = _validateDirectory(directory, archiveLength, limits);
    entries.sort(
      (left, right) =>
          compareMangaArchivePagePathsNaturally(left.name, right.name),
    );

    var actualTotalBytes = 0;
    final pages = <Map<String, Object?>>[];
    final outputWidth = entries.length.toString().length < 4
        ? 4
        : entries.length.toString().length;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final remainingArchiveBytes =
          limits.maximumUncompressedBytes - actualTotalBytes;
      if (remainingArchiveBytes <= 0) {
        throw const MangaArchiveException(
          MangaArchiveFailureCode.archiveTooLarge,
          'The archive exceeds the uncompressed size limit.',
        );
      }
      final outputLimit = remainingArchiveBytes < limits.maximumPageBytes
          ? remainingArchiveBytes
          : limits.maximumPageBytes;
      final outputBase = (index + 1).toString().padLeft(outputWidth, '0');
      final finalFile = File(
        path.join(
          operationDirectory.path,
          '$outputBase${entry.expectedType.extension}',
        ),
      );
      final partFile = File('${finalFile.path}.part');
      final output = _BoundedFileOutputStream(partFile.path, outputLimit);
      try {
        entry.file.decompress(output);
        output.closeSync();
      } catch (_) {
        output.closeSync();
        rethrow;
      }

      if (output.length != entry.uncompressedSize) {
        throw MangaArchiveException(
          MangaArchiveFailureCode.corruptEntry,
          'A page did not match its declared size.',
          entryName: entry.name,
        );
      }
      if (output.crc32 != entry.crc32) {
        throw MangaArchiveException(
          MangaArchiveFailureCode.corruptEntry,
          'A page failed its integrity check.',
          entryName: entry.name,
        );
      }

      final MangaImageInfo image;
      try {
        image = inspectMangaImage(partFile.readAsBytesSync());
      } on MangaImageValidationException catch (error) {
        throw MangaArchiveException(
          error.failure == MangaImageValidationFailure.dimensionsExceeded
              ? MangaArchiveFailureCode.unsafeImageDimensions
              : MangaArchiveFailureCode.invalidImage,
          error.message,
          entryName: entry.name,
        );
      }
      if (image.type != entry.expectedType) {
        throw MangaArchiveException(
          MangaArchiveFailureCode.invalidImage,
          'A page extension does not match its image content.',
          entryName: entry.name,
        );
      }

      partFile.renameSync(finalFile.path);
      actualTotalBytes += output.length;
      pages.add(<String, Object?>{
        'index': index,
        'originalPath': entry.name,
        'filePath': finalFile.path,
        'imageType': image.type.index,
        'byteLength': output.length,
      });
    }
    return <String, Object?>{
      'ok': true,
      'pages': pages,
      'totalUncompressedBytes': actualTotalBytes,
    };
  } finally {
    input?.closeSync();
  }
}

void _validateZipSignatureSync(File archiveFile) {
  final randomAccess = archiveFile.openSync();
  try {
    final signature = randomAccess.readSync(4);
    final isZip =
        signature.length == 4 &&
        signature[0] == 0x50 &&
        signature[1] == 0x4b &&
        ((signature[2] == 0x03 && signature[3] == 0x04) ||
            (signature[2] == 0x05 && signature[3] == 0x06) ||
            (signature[2] == 0x07 && signature[3] == 0x08));
    if (!isZip) {
      throw const MangaArchiveException(
        MangaArchiveFailureCode.invalidArchive,
        'The file is not a valid ZIP/CBZ archive.',
      );
    }
  } finally {
    randomAccess.closeSync();
  }
}

List<_ValidatedZipEntry> _validateDirectory(
  ZipDirectory directory,
  int archiveLength,
  MangaArchiveLimits limits,
) {
  if (directory.filePosition < 0 ||
      directory.centralDirectoryOffset < 0 ||
      directory.centralDirectorySize < 0 ||
      directory.centralDirectoryOffset + directory.centralDirectorySize >
          archiveLength ||
      directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0 ||
      directory.totalCentralDirectoryEntriesOnThisDisk !=
          directory.totalCentralDirectoryEntries ||
      directory.totalCentralDirectoryEntries != directory.fileHeaders.length) {
    throw const MangaArchiveException(
      MangaArchiveFailureCode.invalidArchive,
      'The ZIP/CBZ directory is incomplete or unsupported.',
    );
  }
  if (directory.fileHeaders.length > limits.maximumEntries) {
    throw const MangaArchiveException(
      MangaArchiveFailureCode.tooManyPages,
      'The archive contains too many entries.',
    );
  }

  var declaredTotalBytes = 0;
  final pages = <_ValidatedZipEntry>[];
  final names = <String>{};

  for (final header in directory.fileHeaders) {
    final file = header.file;
    if (file == null ||
        header.filename != file.filename ||
        header.diskNumberStart != 0 ||
        header.generalPurposeBitFlag != file.flags ||
        header.crc32 != file.crc32 ||
        header.compressedSize != file.compressedSize ||
        header.uncompressedSize != file.uncompressedSize) {
      throw const MangaArchiveException(
        MangaArchiveFailureCode.invalidArchive,
        'The ZIP/CBZ directory contains inconsistent entries.',
      );
    }
    final name = file.filename;
    _validateEntryPath(name);
    if (!names.add(name)) {
      throw MangaArchiveException(
        MangaArchiveFailureCode.invalidArchive,
        'The archive contains duplicate entry paths.',
        entryName: name,
      );
    }

    final mode = header.externalFileAttributes >> 16;
    final fileType = mode & 0xf000;
    if (fileType == 0xa000) {
      throw MangaArchiveException(
        MangaArchiveFailureCode.symbolicLink,
        'Symbolic links are not allowed in manga archives.',
        entryName: name,
      );
    }
    final isDirectory = name.endsWith('/') || fileType == 0x4000;
    if (isDirectory) continue;
    if (fileType != 0 && fileType != 0x8000) {
      throw MangaArchiveException(
        MangaArchiveFailureCode.unsupportedEntry,
        'Special filesystem entries are not allowed.',
        entryName: name,
      );
    }
    if (header.generalPurposeBitFlag & 0x1 != 0 ||
        !_hasMatchingSupportedCompression(header, file)) {
      throw MangaArchiveException(
        MangaArchiveFailureCode.unsupportedEntry,
        'Encrypted or unsupported ZIP entries are not allowed.',
        entryName: name,
      );
    }

    final expectedType = _imageTypeForPath(name);
    if (expectedType == null) {
      throw MangaArchiveException(
        MangaArchiveFailureCode.unsupportedEntry,
        'Only JPG, JPEG, PNG, WebP, and GIF pages are allowed.',
        entryName: name,
      );
    }
    if (pages.length >= limits.maximumPages) {
      throw const MangaArchiveException(
        MangaArchiveFailureCode.tooManyPages,
        'The archive contains more than 1000 image pages.',
      );
    }

    final uncompressedSize = header.uncompressedSize;
    final compressedSize = header.compressedSize;
    if (uncompressedSize <= 0 || uncompressedSize > limits.maximumPageBytes) {
      throw MangaArchiveException(
        MangaArchiveFailureCode.pageTooLarge,
        'A page is empty or exceeds the per-page size limit.',
        entryName: name,
      );
    }
    declaredTotalBytes += uncompressedSize;
    if (declaredTotalBytes > limits.maximumUncompressedBytes) {
      throw const MangaArchiveException(
        MangaArchiveFailureCode.archiveTooLarge,
        'The archive exceeds the uncompressed size limit.',
      );
    }
    if (compressedSize <= 0 ||
        uncompressedSize > compressedSize * limits.maximumCompressionRatio) {
      throw MangaArchiveException(
        MangaArchiveFailureCode.suspiciousCompression,
        'A page has an unsafe compression ratio.',
        entryName: name,
      );
    }

    pages.add(
      _ValidatedZipEntry(
        name: name,
        file: file,
        expectedType: expectedType,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        crc32: header.crc32,
      ),
    );
  }

  if (pages.isEmpty) {
    throw const MangaArchiveException(
      MangaArchiveFailureCode.emptyArchive,
      'The archive does not contain any supported image pages.',
    );
  }
  return pages;
}

Map<String, Object?> _limitsToMessage(MangaArchiveLimits limits) =>
    <String, Object?>{
      'maximumPages': limits.maximumPages,
      'maximumPageBytes': limits.maximumPageBytes,
      'maximumUncompressedBytes': limits.maximumUncompressedBytes,
      'maximumCompressionRatio': limits.maximumCompressionRatio,
      'maximumEntries': limits.maximumEntries,
    };

MangaArchiveLimits _limitsFromMessage(Map<String, Object?> message) =>
    MangaArchiveLimits(
      maximumPages: message['maximumPages']! as int,
      maximumPageBytes: message['maximumPageBytes']! as int,
      maximumUncompressedBytes: message['maximumUncompressedBytes']! as int,
      maximumCompressionRatio: message['maximumCompressionRatio']! as int,
      maximumEntries: message['maximumEntries']! as int,
    );

Map<String, Object?> _exceptionToWorkerMessage(MangaArchiveException error) =>
    <String, Object?>{
      'ok': false,
      'code': error.code.index,
      'message': error.message,
      'entryName': error.entryName,
    };

MangaArchiveException _exceptionFromWorkerMessage(
  Map<String, Object?> message,
) {
  final codeIndex = message['code'];
  final code =
      codeIndex is int &&
          codeIndex >= 0 &&
          codeIndex < MangaArchiveFailureCode.values.length
      ? MangaArchiveFailureCode.values[codeIndex]
      : MangaArchiveFailureCode.invalidArchive;
  return MangaArchiveException(
    code,
    message['message'] is String
        ? message['message']! as String
        : 'The ZIP/CBZ archive is corrupt or unsupported.',
    entryName: message['entryName'] as String?,
  );
}

MangaArchivePage _pageFromWorkerMessage(Map<String, Object?> message) {
  final typeIndex = message['imageType']! as int;
  if (typeIndex < 0 || typeIndex >= MangaArchiveImageType.values.length) {
    throw const MangaArchiveException(
      MangaArchiveFailureCode.invalidArchive,
      'The ZIP/CBZ worker returned invalid page metadata.',
    );
  }
  return MangaArchivePage(
    index: message['index']! as int,
    originalPath: message['originalPath']! as String,
    file: File(message['filePath']! as String),
    imageType: MangaArchiveImageType.values[typeIndex],
    byteLength: message['byteLength']! as int,
  );
}

bool _hasMatchingSupportedCompression(ZipFileHeader header, ZipFile file) {
  final expected = switch (header.compressionMethod) {
    0 => CompressionType.none,
    8 => CompressionType.deflate,
    12 => CompressionType.bzip2,
    _ => null,
  };
  return expected != null && file.compressionMethod == expected;
}

class _ValidatedZipEntry {
  const _ValidatedZipEntry({
    required this.name,
    required this.file,
    required this.expectedType,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.crc32,
  });

  final String name;
  final ZipFile file;
  final MangaArchiveImageType expectedType;
  final int compressedSize;
  final int uncompressedSize;
  final int crc32;
}

class _BoundedFileOutputStream extends OutputStream {
  _BoundedFileOutputStream(String filePath, this.maximumBytes)
    : _output = OutputFileStream(filePath),
      super(byteOrder: ByteOrder.littleEndian);

  final int maximumBytes;
  final OutputFileStream _output;
  int _length = 0;
  int _crc32 = 0;

  @override
  int get length => _length;

  int get crc32 => _crc32;

  @override
  bool get isOpen => _output.isOpen;

  @override
  void clear() {
    _output.clear();
    _length = 0;
    _crc32 = 0;
  }

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  void flush() => _output.flush();

  @override
  void writeByte(int value) => writeBytes(<int>[value]);

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw RangeError.range(count, 0, bytes.length, 'length');
    }
    if (_length + count > maximumBytes) {
      throw const MangaArchiveException(
        MangaArchiveFailureCode.pageTooLarge,
        'A page expanded beyond its safe extraction limit.',
      );
    }
    final written = count == bytes.length ? bytes : bytes.sublist(0, count);
    _crc32 = getCrc32(written, _crc32);
    _output.writeBytes(written);
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final count = stream.length < chunkSize ? stream.length : chunkSize;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
}

void _validateEntryPath(String entryName) {
  if (entryName.isEmpty ||
      entryName.contains('\u0000') ||
      entryName.contains('\\') ||
      entryName.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(entryName)) {
    throw MangaArchiveException(
      MangaArchiveFailureCode.unsafeEntryPath,
      'The archive contains an unsafe entry path.',
      entryName: entryName,
    );
  }

  final normalized = entryName.endsWith('/')
      ? entryName.substring(0, entryName.length - 1)
      : entryName;
  final segments = normalized.split('/');
  if (normalized.isEmpty ||
      segments.any(
        (segment) => segment.isEmpty || segment == '.' || segment == '..',
      )) {
    throw MangaArchiveException(
      MangaArchiveFailureCode.unsafeEntryPath,
      'The archive contains an unsafe entry path.',
      entryName: entryName,
    );
  }
}

MangaArchiveImageType? _imageTypeForPath(String entryName) {
  return switch (path.extension(entryName).toLowerCase()) {
    '.jpg' || '.jpeg' => MangaArchiveImageType.jpeg,
    '.png' => MangaArchiveImageType.png,
    '.webp' => MangaArchiveImageType.webp,
    '.gif' => MangaArchiveImageType.gif,
    _ => null,
  };
}

int compareMangaArchivePagePathsNaturally(String left, String right) {
  final leftTokens = _naturalTokens(left);
  final rightTokens = _naturalTokens(right);
  final commonLength = leftTokens.length < rightTokens.length
      ? leftTokens.length
      : rightTokens.length;

  for (var index = 0; index < commonLength; index++) {
    final leftToken = leftTokens[index];
    final rightToken = rightTokens[index];
    final leftIsNumber = _isAsciiDigit(leftToken.codeUnitAt(0));
    final rightIsNumber = _isAsciiDigit(rightToken.codeUnitAt(0));

    int comparison;
    if (leftIsNumber && rightIsNumber) {
      comparison = _compareDigitRuns(leftToken, rightToken);
    } else {
      comparison = leftToken.toLowerCase().compareTo(rightToken.toLowerCase());
    }
    if (comparison != 0) return comparison;
  }

  final lengthComparison = leftTokens.length.compareTo(rightTokens.length);
  if (lengthComparison != 0) return lengthComparison;
  return left.compareTo(right);
}

List<String> _naturalTokens(String value) {
  if (value.isEmpty) return const <String>[];
  final tokens = <String>[];
  var start = 0;
  var digits = _isAsciiDigit(value.codeUnitAt(0));
  for (var index = 1; index < value.length; index++) {
    final nextDigits = _isAsciiDigit(value.codeUnitAt(index));
    if (digits != nextDigits) {
      tokens.add(value.substring(start, index));
      start = index;
      digits = nextDigits;
    }
  }
  tokens.add(value.substring(start));
  return tokens;
}

int _compareDigitRuns(String left, String right) {
  final leftSignificant = left.replaceFirst(RegExp(r'^0+'), '');
  final rightSignificant = right.replaceFirst(RegExp(r'^0+'), '');
  final normalizedLeft = leftSignificant.isEmpty ? '0' : leftSignificant;
  final normalizedRight = rightSignificant.isEmpty ? '0' : rightSignificant;
  final lengthComparison = normalizedLeft.length.compareTo(
    normalizedRight.length,
  );
  if (lengthComparison != 0) return lengthComparison;
  final valueComparison = normalizedLeft.compareTo(normalizedRight);
  if (valueComparison != 0) return valueComparison;
  return left.length.compareTo(right.length);
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

Future<void> _deleteOperationDirectory(Directory? directory) async {
  if (directory == null) return;
  for (var attempt = 0; attempt < 4; attempt++) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (attempt < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }
}

void _deleteOperationDirectorySync(Directory directory) {
  try {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  } on FileSystemException {
    // The parent isolate retries after a worker failure or cancellation.
  }
}
