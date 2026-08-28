import 'package:anime_tv/core/widgets/trusted_local_artwork_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = TrustedLocalArtworkRegistry.instance;

  setUp(registry.clearForTesting);

  test('accepts only the exact registered local artwork capability', () {
    final trusted = Uri.file('/app/offline_downloads/artwork/cover.png');
    registry.register(trusted);

    expect(registry.owns(trusted), isTrue);
    expect(
      registry.owns(Uri.file('/app/offline_downloads/artwork/other.png')),
      isFalse,
    );
    expect(registry.owns(Uri.parse('https://example.com/cover.png')), isFalse);
  });

  test('does not register file URLs with query or fragment data', () {
    registry.register(Uri.parse('file:///app/cover.png?secret=value'));
    registry.register(Uri.parse('file:///app/cover.png#fragment'));

    expect(registry.owns(Uri.file('/app/cover.png')), isFalse);
  });
}
