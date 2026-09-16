import 'dart:convert';

import 'package:anime_tv/features/aniyomi/data/aniyomi_repository_parser.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:flutter_test/flutter_test.dart';

final _indexUri = Uri.parse('https://catalog.example/repo/index.min.json');
final _fingerprint = List.filled(64, 'a').join();

Map<String, Object?> _source({Object? id = '9223372036854775807'}) => {
  'id': id,
  'lang': 'en',
  'name': 'Example source',
  'baseUrl': 'https://source.example',
};

Map<String, Object?> _extension({
  String packageName = 'eu.kanade.tachiyomi.animeextension.en.example',
  Object? id = '9223372036854775807',
}) => {
  'name': 'Aniyomi: Example',
  'pkg': packageName,
  'apk': '$packageName-v14.7.apk',
  'lang': 'en',
  'code': 7,
  'version': '14.7',
  'nsfw': 0,
  'sources': [_source(id: id)],
};

Map<String, Object?> _metadata() => {
  'meta': <String, Object?>{
    'name': 'Example repository',
    'shortName': 'Example',
    'website': 'https://catalog.example',
    'signingKeyFingerprint': _fingerprint,
  },
};

Map<String, Object?> _storeExtension() => {
  'name': 'Example',
  'packageName': 'eu.kanade.tachiyomi.animeextension.en.example',
  'resources': {
    'apkUrl': 'https://download.example/example.apk',
    'iconUrl': 'https://images.example/example.png',
  },
  'extensionLib': '16',
  'versionCode': '12',
  'versionName': '1.0.12',
  'contentWarning': 'CONTENT_WARNING_SAFE',
  'isTorrent': false,
  'sources': [
    {
      'id': '9007199254740993',
      'name': 'Example source',
      'language': 'en-US',
      'homeUrl': 'https://source.example',
      'mirrorUrls': ['https://mirror.example'],
    },
  ],
};

Map<String, Object?> _store({
  Map<String, Object?>? extension,
  List<Map<String, Object?>>? extensions,
}) => {
  'name': 'Example repository',
  'badgeLabel': 'Example',
  'signingKey': _fingerprint,
  'contact': {'website': 'https://catalog.example', 'discord': null},
  'extensionList': {
    'extensions': extensions ?? [extension ?? _storeExtension()],
  },
  'extensionListUrl': null,
};

AniyomiRepositoryDocument _parse(
  Object? document, {
  AniyomiMediaKind kind = AniyomiMediaKind.anime,
  Uri? uri,
}) => parseAniyomiRepository(
  jsonEncode(document),
  repositoryUri: uri ?? _indexUri,
  kind: kind,
);

Matcher _error(AniyomiRepositoryParseError code) => throwsA(
  isA<AniyomiRepositoryParseException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);

void main() {
  test('legacy index resolves only sibling APK/icon resources', () {
    final result = _parse([_extension()]);
    expect(result.format, AniyomiRepositoryFormat.legacyIndex);
    expect(result.isMetadataOnly, isFalse);
    expect(result.metadata, isNull);
    expect(result.legacyIndexUri, isNull);
    final extension = result.extensions.single;
    expect(
      extension.identityKey,
      'aniyomi:anime:eu.kanade.tachiyomi.animeextension.en.example',
    );
    expect(extension.extensionLib, '14');
    expect(extension.versionCode, 7);
    expect(
      extension.apkUri.toString(),
      'https://catalog.example/repo/apk/eu.kanade.tachiyomi.animeextension.en.example-v14.7.apk',
    );
    expect(
      extension.iconUri.toString(),
      'https://catalog.example/repo/icon/eu.kanade.tachiyomi.animeextension.en.example.png',
    );
    expect(extension.sources.single.id, '9223372036854775807');
  });

  test('anime and manga identities are disjoint for equal source IDs', () {
    final anime = _parse([_extension()]).extensions.single;
    final entry = _extension()..['version'] = '1.4.7';
    final manga = _parse([
      entry,
    ], kind: AniyomiMediaKind.manga).extensions.single;
    expect(manga.extensionLib, '1.4');
    expect(anime.identityKey, isNot(manga.identityKey));
    expect(
      anime.sources.single.identityKey,
      isNot(manga.sources.single.identityKey),
    );
    expect(
      manga.sources.single.identityKey,
      'aniyomi:manga:source:9223372036854775807',
    );
  });

  test(
    'preserves signed 64-bit string and native integer boundaries exactly',
    () {
      for (final id in <Object>[
        '9223372036854775807',
        '-9223372036854775808',
        9223372036854775807,
        -9223372036854775808,
        9007199254740993,
        0,
      ]) {
        expect(
          _parse([_extension(id: id)]).extensions.single.sources.single.id,
          id.toString(),
        );
      }
    },
  );

  test(
    'rejects doubles, exponent notation, noncanonical and out-of-range IDs',
    () {
      for (final id in <Object?>[
        1.0,
        9007199254740993.0,
        1.25,
        '1e3',
        '01',
        '+1',
        '-0',
        ' 1',
        '1 ',
        '9223372036854775808',
        '-9223372036854775809',
        '',
        true,
        null,
      ]) {
        expect(
          () => _parse([_extension(id: id)]),
          _error(AniyomiRepositoryParseError.invalidDocument),
          reason: '$id',
        );
      }
      final json = jsonEncode([
        _extension(id: 'TOKEN'),
      ]).replaceAll('"TOKEN"', '1e3');
      expect(
        () => parseAniyomiRepository(
          json,
          repositoryUri: _indexUri,
          kind: AniyomiMediaKind.anime,
        ),
        _error(AniyomiRepositoryParseError.invalidDocument),
      );
    },
  );

  test('rejects duplicate and case-ambiguous package identities', () {
    for (final packageName in [
      'eu.kanade.tachiyomi.animeextension.en.example',
      'eu.kanade.tachiyomi.animeextension.en.Example',
    ]) {
      expect(
        () => _parse([
          _extension(id: '1'),
          _extension(packageName: packageName, id: '2'),
        ]),
        _error(AniyomiRepositoryParseError.invalidDocument),
      );
    }
  });

  test('rejects duplicate source identities within and across extensions', () {
    final one = _extension()..['sources'] = [_source(id: '1'), _source(id: 1)];
    expect(
      () => _parse([one]),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );
    expect(
      () => _parse([
        _extension(id: '1'),
        _extension(packageName: 'com.example.other', id: 1),
      ]),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );
  });

  test(
    'legacy missing source descriptors do not manufacture source id zero',
    () {
      final entry = _extension()..['sources'] = null;
      expect(_parse([entry]).extensions.single.sources, isEmpty);
    },
  );

  test(
    'metadata is advisory and explicitly separate from an empty catalog',
    () {
      final metadata = _metadata();
      (metadata['meta'] as Map)['signingKeyFingerprint'] = _fingerprint
          .toUpperCase();
      final result = _parse(
        metadata,
        uri: Uri.parse('https://catalog.example/repo/repo.json'),
      );
      expect(result.isMetadataOnly, isTrue);
      expect(result.extensions, isEmpty);
      expect(result.metadata!.name, 'Example repository');
      expect(result.metadata!.signingKeyFingerprint, _fingerprint);
      expect(
        result.legacyIndexUri.toString(),
        'https://catalog.example/repo/index.min.json',
      );
      expect(_parse([]).isMetadataOnly, isFalse);
    },
  );

  test(
    'metadata accepts absent shortName but rejects malformed fingerprints',
    () {
      final metadata = _metadata();
      final meta = metadata['meta'] as Map;
      meta.remove('shortName');
      expect(_parse(metadata).metadata!.shortName, isNull);
      for (final fingerprint in [
        '',
        'abcdef',
        List.filled(64, 'g').join(),
        'SHA256:$_fingerprint',
        null,
        42,
      ]) {
        meta['signingKeyFingerprint'] = fingerprint;
        expect(
          () => _parse(metadata),
          throwsA(isA<AniyomiRepositoryParseException>()),
        );
      }
    },
  );

  test('parses inline anime store JSON without claiming API compatibility', () {
    final entry = _storeExtension()..['extensionLib'] = '17';
    final result = _parse(_store(extension: entry));
    expect(result.format, AniyomiRepositoryFormat.animeStore);
    expect(result.metadata!.signingKeyFingerprint, _fingerprint);
    final extension = result.extensions.single;
    expect(extension.extensionLib, '17');
    expect(extension.language, 'en-us');
    expect(extension.versionCode, 12);
    expect(extension.sources.single.id, '9007199254740993');
    expect(extension.apkUri.host, 'download.example');
    expect(extension.isNsfw, isFalse);
    expect(extension.isTorrent, isFalse);
  });

  test('new source optional home URL is not replaced by a fabricated URL', () {
    final entry = _storeExtension();
    (entry['sources'] as List).single.remove('homeUrl');
    expect(
      _parse(_store(extension: entry)).extensions.single.sources.single.homeUri,
      isNull,
    );
  });

  test('normalizes surrounding source display-name whitespace only', () {
    final entry = _storeExtension();
    final source = (entry['sources'] as List).single as Map;
    source['name'] = 'DailySuka ';
    expect(
      _parse(
        _store(extension: entry),
        kind: AniyomiMediaKind.manga,
      ).extensions.single.sources.single.name,
      'DailySuka',
    );
    expect(
      () => _parse(_store(extension: entry)),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );

    source['name'] = 'Daily\nSuka';
    expect(
      () => _parse(_store(extension: entry), kind: AniyomiMediaKind.manga),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );
  });

  test('content warnings are conservative and torrent flag is explicit', () {
    for (final warning in [
      'MIXED',
      'NSFW',
      'UNSPECIFIED',
      'CONTENT_WARNING_MIXED',
      0,
      2,
      3,
    ]) {
      final entry = _storeExtension()..['contentWarning'] = warning;
      expect(_parse(_store(extension: entry)).extensions.single.isNsfw, isTrue);
    }
    final entry = _storeExtension()..['isTorrent'] = true;
    expect(
      _parse(_store(extension: entry)).extensions.single.isTorrent,
      isTrue,
    );
    entry['isTorrent'] = 'true';
    expect(
      () => _parse(_store(extension: entry)),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );
    entry['isTorrent'] = false;
    entry['contentWarning'] = 'safe-ish';
    expect(
      () => _parse(_store(extension: entry)),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );
  });

  test('parses canonical inline manga stores and the other language token', () {
    final entry = _storeExtension()
      ..['packageName'] = 'eu.kanade.tachiyomi.extension.all.example'
      ..['extensionLib'] = '1.4';
    ((entry['sources'] as List).single as Map)['language'] = 'other';

    expect(
      () => _parse(_store(extension: entry)),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );

    final result = _parse(
      _store(extension: entry),
      kind: AniyomiMediaKind.manga,
    );

    expect(result.format, AniyomiRepositoryFormat.animeStore);
    expect(result.kind, AniyomiMediaKind.manga);
    final extension = result.extensions.single;
    expect(extension.kind, AniyomiMediaKind.manga);
    expect(extension.extensionLib, '1.4');
    expect(extension.language, 'other');
    expect(extension.sources.single.language, 'other');
    expect(extension.sources.single.kind, AniyomiMediaKind.manga);
  });

  test('isolates unsafe entries without relaxing public HTTPS checks', () {
    final unsafeDownload = _storeExtension();
    (unsafeDownload['resources'] as Map)['apkUrl'] =
        'https://127.0.0.1/example.apk';

    // This valid entry deliberately reuses the skipped entry's package/source
    // identities, proving an unsafe entry cannot reserve either identity.
    final safe = _storeExtension();

    final unsafeSource = _storeExtension()
      ..['packageName'] = 'eu.kanade.tachiyomi.extension.en.selfhosted';
    ((unsafeSource['sources'] as List).single as Map)
      ..['id'] = '9007199254740994'
      ..['homeUrl'] = 'http://127.0.0.1:3000'
      ..['mirrorUrls'] = ['https://192.168.1.1'];

    final result = _parse(
      _store(extensions: [unsafeDownload, safe, unsafeSource]),
      kind: AniyomiMediaKind.manga,
    );

    expect(result.extensions, hasLength(2));
    expect(
      result.extensions.map((extension) => extension.packageName),
      containsAll(<Object?>[safe['packageName'], unsafeSource['packageName']]),
    );
    expect(
      result.extensions
          .singleWhere(
            (extension) => extension.packageName == unsafeSource['packageName'],
          )
          .sources
          .single
          .homeUri,
      isNull,
    );

    final reversed = _parse(
      _store(extensions: [safe, unsafeDownload]),
      kind: AniyomiMediaKind.manga,
    );
    expect(reversed.extensions, hasLength(1));
    expect(reversed.extensions.single.packageName, safe['packageName']);

    final unsafeDuplicateSource = _storeExtension()
      ..['packageName'] = 'eu.kanade.tachiyomi.extension.en.unsafe_duplicate';
    (unsafeDuplicateSource['resources'] as Map)['iconUrl'] =
        'https://localhost/example.png';
    final sourceReversed = _parse(
      _store(extensions: [safe, unsafeDuplicateSource]),
      kind: AniyomiMediaKind.manga,
    );
    expect(sourceReversed.extensions, hasLength(1));
    expect(sourceReversed.extensions.single.packageName, safe['packageName']);
  });

  test('inline manga raw source bound is counted exactly once', () {
    var nextSourceId = 1;
    final atLimit = List.generate(64, (extensionIndex) {
      final entry = _storeExtension()
        ..['packageName'] =
            'eu.kanade.tachiyomi.extension.en.bound_$extensionIndex'
        ..['sources'] = List.generate(
          AniyomiRepositoryLimits.maxSourcesPerExtension,
          (_) => <String, Object?>{
            'id': '${nextSourceId++}',
            'name': 'Source',
            'language': 'en',
          },
        );
      return entry;
    });

    final result = _parse(
      _store(extensions: atLimit),
      kind: AniyomiMediaKind.manga,
    );
    expect(
      result.extensions.expand((extension) => extension.sources),
      hasLength(AniyomiRepositoryLimits.maxSources),
    );

    final overflow = _storeExtension()
      ..['packageName'] = 'eu.kanade.tachiyomi.extension.en.bound_overflow'
      ..['sources'] = [
        <String, Object?>{
          'id': '${nextSourceId++}',
          'name': 'Source',
          'language': 'en',
        },
      ];
    expect(
      () => _parse(
        _store(extensions: [...atLimit, overflow]),
        kind: AniyomiMediaKind.manga,
      ),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );
  });

  test('inline manga recovery keeps non-entry failures fatal', () {
    final duplicate = _store(
      extensions: [_storeExtension(), _storeExtension()],
    );
    expect(
      () => _parse(duplicate, kind: AniyomiMediaKind.manga),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );

    final malformed = _store(extension: _storeExtension()..['name'] = '');
    expect(
      () => _parse(malformed, kind: AniyomiMediaKind.manga),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );

    final oversized = _storeExtension()
      ..['sources'] = List.filled(
        AniyomiRepositoryLimits.maxSourcesPerExtension + 1,
        null,
      );
    expect(
      () => _parse(_store(extension: oversized), kind: AniyomiMediaKind.manga),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );

    final unsafeRoot = _store();
    (unsafeRoot['contact'] as Map)['website'] = 'https://127.0.0.1';
    expect(
      () => _parse(unsafeRoot, kind: AniyomiMediaKind.manga),
      _error(AniyomiRepositoryParseError.unsafeResource),
    );

    final delegated = _store()
      ..['extensionListUrl'] = 'https://catalog.example/list.json';
    expect(
      () => _parse(delegated, kind: AniyomiMediaKind.manga),
      _error(AniyomiRepositoryParseError.delegatedIndex),
    );
  });

  test('delegated indexes are explicit failures even with inline entries', () {
    final legacy = _metadata()
      ..['index_v2'] = 'https://catalog.example/index.pb';
    expect(
      () => _parse(legacy),
      _error(AniyomiRepositoryParseError.delegatedIndex),
    );
    final store = _store()
      ..['extensionListUrl'] = 'https://catalog.example/list.json';
    expect(
      () => _parse(store),
      _error(AniyomiRepositoryParseError.delegatedIndex),
    );
  });

  test('validates delegated URLs instead of echoing unsafe referrals', () {
    final legacy = _metadata()..['index_v2'] = 'https://127.0.0.1/index.pb';
    expect(
      () => _parse(legacy),
      _error(AniyomiRepositoryParseError.unsafeResource),
    );
    final store = _store()..['extensionListUrl'] = 'file:///storage/list.json';
    expect(
      () => _parse(store),
      _error(AniyomiRepositoryParseError.unsafeResource),
    );
  });

  test('rejects protobuf and gzip explicitly without decoding or fetching', () {
    for (final extension in ['pb', 'pb.gz', 'json.gz']) {
      expect(
        () => _parse(
          [],
          uri: Uri.parse('https://catalog.example/index.$extension'),
        ),
        _error(AniyomiRepositoryParseError.unsupportedFormat),
      );
    }
    for (final payload in [
      '',
      '\u001f\u008b',
      '\n\u0012protobuf',
      'not json',
    ]) {
      expect(
        () => parseAniyomiRepository(
          payload,
          repositoryUri: _indexUri,
          kind: AniyomiMediaKind.anime,
        ),
        _error(AniyomiRepositoryParseError.unsupportedFormat),
      );
    }
  });

  test(
    'rejects insecure, private, credential-bearing, and fragmented URLs',
    () {
      for (final url in [
        'http://catalog.example/repo.json',
        'https://127.0.0.1/repo.json',
        'https://10.0.0.1/repo.json',
        'https://[::1]/repo.json',
        'https://user:secret@catalog.example/repo.json',
        'https://catalog.example/repo.json#fragment',
      ]) {
        expect(
          () => _parse([], uri: Uri.parse(url)),
          _error(AniyomiRepositoryParseError.unsafeResource),
          reason: url,
        );
      }
    },
  );

  test('rejects malformed APK filenames and path traversal encodings', () {
    for (final filename in [
      '../evil.apk',
      'a/evil.apk',
      r'a\evil.apk',
      '%2e%2e.apk',
      '%252e%252e.apk',
      'a%2fevil.apk',
      'a%5cevil.apk',
      '//host/evil.apk',
      'https://elsewhere.example/evil.apk',
      'evil.apk?x=1',
      'evil.apk#x',
      'evil.zip',
      '.evil.apk',
      'a..b.apk',
    ]) {
      final entry = _extension()..['apk'] = filename;
      expect(
        () => _parse([entry]),
        _error(AniyomiRepositoryParseError.unsafeResource),
        reason: filename,
      );
    }
  });

  test('validates explicit APK and icon paths before Uri normalizes them', () {
    for (final path in [
      '/../evil.apk',
      '/%2e%2e/evil.apk',
      '/%252e%252e/evil.apk',
      '/x%2fy.apk',
      '/x%5cy.apk',
      '/x%00y.apk',
      '/%zz.apk',
    ]) {
      final entry = _storeExtension();
      (entry['resources'] as Map)['apkUrl'] = 'https://download.example$path';
      expect(
        () => _parse(_store(extension: entry)),
        _error(AniyomiRepositoryParseError.unsafeResource),
        reason: path,
      );
    }
    final entry = _storeExtension();
    (entry['resources'] as Map)['iconUrl'] = 'https://localhost/icon.png';
    expect(
      () => _parse(_store(extension: entry)),
      _error(AniyomiRepositoryParseError.unsafeResource),
    );
  });

  test('validates source home/mirror and repository website URLs', () {
    final entry = _extension();
    (entry['sources'] as List).single['baseUrl'] = 'http://source.example';
    expect(
      () => _parse([entry]),
      _error(AniyomiRepositoryParseError.unsafeResource),
    );
    final storeEntry = _storeExtension();
    (storeEntry['sources'] as List).single['mirrorUrls'] = [
      'https://192.168.1.1',
    ];
    expect(
      () => _parse(_store(extension: storeEntry)),
      _error(AniyomiRepositoryParseError.unsafeResource),
    );
    final metadata = _metadata();
    (metadata['meta'] as Map)['website'] = 'https://localhost';
    expect(
      () => _parse(metadata),
      _error(AniyomiRepositoryParseError.unsafeResource),
    );
  });

  test('rejects bad schemas, package names, flags, and numeric versions', () {
    for (final change in <Map<String, Object?>>[
      {'pkg': '../bad'},
      {'name': ''},
      {'code': 1.0},
      {'code': 0},
      {'code': '01'},
      {'version': '14'},
      {'version': '14.hello'},
      {'nsfw': true},
      {'nsfw': 2},
      {'sources': {}},
      {'lang': 'english'},
    ]) {
      expect(
        () => _parse([_extension()..addAll(change)]),
        _error(AniyomiRepositoryParseError.invalidDocument),
        reason: '$change',
      );
    }
    expect(
      () => _parse({'extensions': []}),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );
    expect(
      () => _parse([null]),
      _error(AniyomiRepositoryParseError.invalidDocument),
    );
  });

  test('limits payload bytes before decoding, including multibyte UTF-8', () {
    final oversized = ' ' * (AniyomiRepositoryLimits.maxPayloadBytes + 1);
    expect(
      () => parseAniyomiRepository(
        oversized,
        repositoryUri: _indexUri,
        kind: AniyomiMediaKind.anime,
      ),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );
    final multibyte =
        '"${'é' * (AniyomiRepositoryLimits.maxPayloadBytes ~/ 2)}"';
    expect(
      () => parseAniyomiRepository(
        multibyte,
        repositoryUri: _indexUri,
        kind: AniyomiMediaKind.anime,
      ),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );
  });

  test('limits list counts and strings without dropping malformed entries', () {
    expect(
      () =>
          _parse(List.filled(AniyomiRepositoryLimits.maxExtensions + 1, null)),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );
    final entry = _extension()
      ..['sources'] = List.filled(
        AniyomiRepositoryLimits.maxSourcesPerExtension + 1,
        null,
      );
    expect(
      () => _parse([entry]),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );
    final oversized = _extension()
      ..['unknown'] = 'x' * (AniyomiRepositoryLimits.maxStringLength + 1);
    expect(
      () => _parse([oversized]),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );
    final longName = _extension()..['name'] = 'x' * 257;
    expect(
      () => _parse([longName]),
      _error(AniyomiRepositoryParseError.limitExceeded),
    );
  });

  test(
    'limits nesting before JSON decode but ignores brackets inside strings',
    () {
      final payload = '${'[' * 25}0${']' * 25}';
      expect(
        () => parseAniyomiRepository(
          payload,
          repositoryUri: _indexUri,
          kind: AniyomiMediaKind.anime,
        ),
        _error(AniyomiRepositoryParseError.limitExceeded),
      );
      final entry = _extension()..['unknown'] = '${'[' * 30}\\"${']' * 30}';
      expect(_parse([entry]).extensions, hasLength(1));
    },
  );

  test(
    'malformed JSON is a typed failure without embedding hostile content',
    () {
      expect(
        () => parseAniyomiRepository(
          '[{"secret":"sensitive"}',
          repositoryUri: _indexUri,
          kind: AniyomiMediaKind.anime,
        ),
        _error(AniyomiRepositoryParseError.invalidDocument),
      );
    },
  );

  test('returned catalogs and source lists cannot be mutated', () {
    final result = _parse([_extension()]);
    expect(() => result.extensions.clear(), throwsUnsupportedError);
    expect(
      () => result.extensions.single.sources.clear(),
      throwsUnsupportedError,
    );
  });
}
