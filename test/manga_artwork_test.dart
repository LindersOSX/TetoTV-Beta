import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  tearDown(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('shows a skeleton, then securely fetched bytes with sizing', (
    tester,
  ) async {
    final completer = Completer<Uint8List>();
    final client = _RecordingPageClient((_) => completer.future);

    await _pumpArtwork(
      tester,
      client: client,
      child: MangaArtwork(
        uri: Uri.parse('https://catalog.example/cover.png'),
        fit: BoxFit.contain,
        cacheWidth: 321,
      ),
    );

    expect(find.byKey(const ValueKey('manga-artwork-loading')), findsOneWidget);
    expect(client.resources, hasLength(1));
    completer.complete(_onePixelPng);
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
    expect(image.image, isA<ResizeImage>());
    expect((image.image as ResizeImage).width, 321);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loads protected credentials only for the exact source origin', (
    tester,
  ) async {
    const sourceId = 'source.example';
    final credentials = MangaSourceCredentialStore(
      const FlutterSecureStorage(),
    );
    await credentials.write(
      sourceId,
      MangaSourceCredential.bearer('top-secret-token'),
    );
    final client = _RecordingPageClient(
      (_) async => throw const MangaPageFetchException('Expected test stop.'),
    );

    await _pumpArtwork(
      tester,
      client: client,
      credentials: credentials,
      child: MangaArtwork(
        uri: Uri.parse('https://catalog.example/covers/one.jpg'),
        sourceId: sourceId,
        sourceUri: Uri.parse('https://catalog.example/opds'),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.resources, hasLength(1));
    expect(
      client.resources.single.headers,
      containsPair('authorization', 'Bearer top-secret-token'),
    );
    expect(
      client.resources.single.toString(),
      isNot(contains('top-secret-token')),
    );
  });

  testWidgets('does not forward source credentials to another cover origin', (
    tester,
  ) async {
    const sourceId = 'source.example';
    final credentials = MangaSourceCredentialStore(
      const FlutterSecureStorage(),
    );
    await credentials.write(
      sourceId,
      MangaSourceCredential.bearer('must-not-leak'),
    );
    final client = _RecordingPageClient(
      (_) async => throw const MangaPageFetchException('Expected test stop.'),
    );

    await _pumpArtwork(
      tester,
      client: client,
      credentials: credentials,
      child: MangaArtwork(
        uri: Uri.parse('https://images.example/cover.jpg'),
        sourceId: sourceId,
        sourceUri: Uri.parse('https://catalog.example/opds'),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.resources.single.headers, isEmpty);
  });

  testWidgets('forwards extension headers and reloads when they change', (
    tester,
  ) async {
    final client = _RecordingPageClient((_) async => _onePixelPng);
    final uri = Uri.parse('https://images.example/cover.jpg');

    await _pumpArtwork(
      tester,
      client: client,
      child: MangaArtwork(
        uri: uri,
        headers: const <String, String>{
          'Referer': 'https://reader.example/title/one',
        },
      ),
    );
    await tester.pumpAndSettle();
    await _pumpArtwork(
      tester,
      client: client,
      child: MangaArtwork(
        uri: uri,
        headers: const <String, String>{
          'Referer': 'https://reader.example/title/two',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(client.resources, hasLength(2));
    expect(
      client.resources.first.headers['Referer'],
      'https://reader.example/title/one',
    );
    expect(
      client.resources.last.headers['Referer'],
      'https://reader.example/title/two',
    );
  });

  testWidgets('rejects non-HTTPS artwork before invoking the fetch client', (
    tester,
  ) async {
    final client = _RecordingPageClient((_) async => _onePixelPng);

    await _pumpArtwork(
      tester,
      client: client,
      child: MangaArtwork(
        uri: Uri.parse('http://catalog.example/cover.jpg'),
        icon: Icons.broken_image_outlined,
      ),
    );
    await tester.pumpAndSettle();

    expect(client.resources, isEmpty);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing artwork keeps the stable fallback without networking', (
    tester,
  ) async {
    final client = _RecordingPageClient((_) async => _onePixelPng);

    await _pumpArtwork(
      tester,
      client: client,
      child: const MangaArtwork(uri: null),
    );

    expect(client.resources, isEmpty);
    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
  });

  testWidgets('an in-flight credential read can finish after widget disposal', (
    tester,
  ) async {
    final credentials = _DelayedCredentials();
    final client = _RecordingPageClient((_) async => _onePixelPng);

    await _pumpArtwork(
      tester,
      client: client,
      credentials: credentials,
      child: MangaArtwork(
        uri: Uri.parse('https://catalog.example/cover.png'),
        sourceId: 'source.example',
        sourceUri: Uri.parse('https://catalog.example/opds'),
      ),
    );
    expect(credentials.requested, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    credentials.complete(const <String, String>{});
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpArtwork(
  WidgetTester tester, {
  required MangaPageFetchClient client,
  required Widget child,
  MangaSourceCredentialStore? credentials,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: <Override>[
      mangaPageFetchClientProvider.overrideWithValue(client),
      if (credentials != null)
        mangaSourceCredentialStoreProvider.overrideWithValue(credentials),
    ],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(child: SizedBox(width: 160, height: 220, child: child)),
      ),
    ),
  ),
);

class _RecordingPageClient extends MangaPageFetchClient {
  _RecordingPageClient(this._load);

  final Future<Uint8List> Function(MangaRemotePageResource resource) _load;
  final List<MangaRemotePageResource> resources = <MangaRemotePageResource>[];

  @override
  Future<Uint8List> fetch(MangaRemotePageResource resource) {
    resources.add(resource);
    return _load(resource);
  }

  @override
  void close() {}
}

class _DelayedCredentials extends MangaSourceCredentialStore {
  _DelayedCredentials() : super(const FlutterSecureStorage());

  final Completer<Map<String, String>> _completer =
      Completer<Map<String, String>>();
  bool requested = false;

  @override
  Future<Map<String, String>> requestHeaders(String sourceId) {
    requested = true;
    return _completer.future;
  }

  void complete(Map<String, String> headers) => _completer.complete(headers);
}

final Uint8List _onePixelPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);
