import 'dart:io';

import 'package:anime_tv/core/updates/release_notes_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'authored customer copy keeps technical and machine details off the screen',
    () {
      final notes = File('docs/RELEASE_NOTES_2.0.74.md').readAsStringSync();
      final raw =
          '$notes\n<!-- tetotv-unreviewed-beta-declaration-base64:\n${'ABC123' * 800} -->';
      final items = customerReleaseHighlights(raw);
      expect(items, hasLength(3));
      expect(items.first, contains('Results vary by device.'));
      expect(items[1], contains('MPV is unchanged.'));
      expect(items.last, contains('time bubble stays.'));
      final summary = formatCustomerReleaseNotes(raw);
      for (final unwanted in [
        '<!--',
        'ABC123',
        '410051',
        'SHA256SUMS',
        '.zip',
        'AI tools',
        'Verification',
        'Focused player',
      ]) {
        expect(summary, isNot(contains(unwanted)));
      }
      expect(
        summary.split('\n').every((line) => line.startsWith('• ')),
        isTrue,
      );
      // No mutation of the source used for update validation.
      expect(raw, contains('<!-- tetotv-android-version-code: 410051 -->'));
    },
  );

  test(
    'legacy screenshot-style notes exclude AI, install, testing and comments',
    () {
      final result = customerReleaseHighlights('''
# TetoTV Beta
> [!WARNING]
> No independent native-license review.
## What's changed
- Added **Media3 SurfaceView** in Settings.
  The same player controls remain.
- Removed the small video preview.
- SurfaceView is optional, not a guaranteed fix for low FPS.
- AI tools assisted with implementation and testing.
## Install
Download TetoTV-universal.apk and SHA256SUMS.
## Verification and channel
- Tests passed.
<!-- tetotv-android-version-code: 410051 -->
<!-- tetotv-unreviewed-beta-declaration-base64: hidden -->
''');
      expect(result, [
        'Added Media3 SurfaceView in Settings. The same player controls remain.',
        'Removed the small video preview.',
        'SurfaceView is optional, not a guaranteed fix for low FPS.',
      ]);
    },
  );

  test(
    'legacy headings, paragraphs, wrapped lists and duplicates are clean',
    () {
      expect(
        customerReleaseHighlights('''
Changes
${'=' * 7}
1. **Fixed playback.**
2. Fixed playback.
3. Improved [captions](https://example.com).

### More
- Better navigation.
## Technical details
- Unit tests passed.
'''),
        ['Fixed playback.', 'Improved captions.', 'Better navigation.'],
      );
      expect(customerReleaseHighlights('Improved the subtitle picker.'), [
        'Improved the subtitle picker.',
      ]);
    },
  );

  test('known customer limitations are not lost behind feature limits', () {
    final notes =
        '## Highlights\n${List.generate(8, (i) => '- Added feature $i.').join('\n')}\n'
        '## Important player differences\n- Subtitle timing adjustments remain MPV-only.\n';
    final items = customerReleaseHighlights(notes);
    expect(items, hasLength(6));
    expect(items.first, 'Subtitle timing adjustments remain MPV-only.');
  });

  test(
    'unclosed and encoded comments or code never expose signature bodies',
    () {
      for (final tail in [
        '<!-- tetotv-native-license-review-status:\nsecret-signature',
        '&lt;!-- comment\nsecret-signature',
        '```json\nsecret-signature',
        '~~~\nsecret-signature',
        '<details><summary>Technical</summary>secret-signature',
      ]) {
        expect(
          customerReleaseHighlights(
            '## Highlights\n- Fixed navigation.\n$tail',
          ),
          ['Fixed navigation.'],
        );
      }
    },
  );

  test('unknown or metadata-only notes never invent customer changes', () {
    for (final notes in [
      '',
      '## Verification\n- Unit tests passed.',
      '<!-- signed release only -->',
      'tetotv-android-version-code: 410051',
      'A' * 500,
    ]) {
      expect(customerReleaseHighlights(notes), isEmpty);
    }
  });

  test(
    'customer warning headings and callouts survive preferred highlights',
    () {
      for (final warning in [
        '## Warnings\n- Existing downloads need to be downloaded again.',
        '## Cautions\n- Existing downloads need to be downloaded again.',
        '> [!WARNING]\n> Existing downloads need to be downloaded again.',
        '> [!IMPORTANT]\n> Existing downloads need to be downloaded again.',
      ]) {
        final items = customerReleaseHighlights(
          '## Highlights\n- Added a player option.\n\n$warning',
        );
        expect(
          items,
          contains('Existing downloads need to be downloaded again.'),
        );
        expect(items, contains('Added a player option.'));
      }
    },
  );

  test('raw marker payloads never become customer bullets', () {
    for (final marker in [
      'tetotv-release-metadata: private-value',
      'signature=private-value',
      'tetotv-native-license-review-status: private-value',
      'base64: private-value',
    ]) {
      expect(
        customerReleaseHighlights(
          '## Highlights\n- Fixed navigation.\n- $marker\n'
          '  wrapped-private-payload\n- Fixed captions.',
        ),
        ['Fixed navigation.', 'Fixed captions.'],
      );
    }
  });

  test(
    'numeric entities and spaced comment openers cannot expose payloads',
    () {
      for (final comment in [
        '&#60;!-- private-payload',
        '&#x3c;!-- private-payload',
        '<! -- private-payload',
        '<!\u0000-- private-payload',
      ]) {
        expect(
          customerReleaseHighlights(
            '## Highlights\n- Fixed navigation.\n$comment',
          ),
          ['Fixed navigation.'],
        );
      }
    },
  );

  test('six bounded complete bullet rows, three shorter inbox rows', () {
    final notes =
        '## Highlights\n${List.generate(40, (i) => '- Feature $i ${'long words ' * 30}').join('\n')}';
    final items = customerReleaseHighlights(notes);
    expect(items, hasLength(6));
    expect(items.every((item) => item.length <= 180), isTrue);
    final inbox = formatCustomerReleaseNotes(
      notes,
      maximumItems: 3,
      maximumItemLength: 140,
    );
    expect(inbox.split('\n'), hasLength(3));
    expect(inbox.length, lessThanOrEqualTo(480));
    expect(inbox.endsWith('…'), isTrue);
  });
}
