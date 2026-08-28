import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('applies marketplace defaults to Seanime payload placeholders', () {
    const payload = '''
class Provider {
  baseUrl = "{{api}}";
  blobDomain = "{{blobDomain}}";
}
''';

    final configured = applyAddonConfigDefaults(payload, const {
      'api': 'https://api.provider.example',
      'blobDomain': 'https://media.provider.example',
    });

    expect(configured, contains('baseUrl = "https://api.provider.example"'));
    expect(
      configured,
      contains('blobDomain = "https://media.provider.example"'),
    );
    expect(configured, isNot(contains('{{')));
  });

  test('rejects configuration expansion beyond the addon payload limit', () {
    final payload =
        'class Provider {}\n${List.filled(100000, '{{api}}').join()}';

    expect(
      () => applyAddonConfigDefaults(payload, {
        'api': 'https://${List.filled(2040, 'a').join()}',
      }),
      throwsA(isA<FormatException>()),
    );
  });
}
