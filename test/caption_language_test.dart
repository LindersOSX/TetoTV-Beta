import 'package:anime_tv/core/preferences/caption_language.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('caption language list is broad and uses unique canonical codes', () {
    final codes = preferredCaptionLanguageOptions
        .map((language) => language.code)
        .toList(growable: false);

    expect(codes.length, greaterThanOrEqualTo(35));
    expect(codes.toSet(), hasLength(codes.length));
    expect(codes, containsAll(['eng', 'spa', 'fra', 'deu', 'jpn', 'zho']));
  });

  test('caption picker keeps common languages first and the rest stable', () {
    final labels = preferredCaptionLanguageOptions
        .map((language) => language.label)
        .toList(growable: false);

    expect(labels.take(6), const [
      'English',
      'Spanish',
      'Italian',
      'Japanese',
      'French',
      'Portuguese',
    ]);
    final remaining = labels.skip(6).toList(growable: false);
    expect(remaining, [...remaining]..sort());
  });

  test('caption language normalization accepts ISO aliases and labels', () {
    for (final testCase in const [
      ('en-US', 'eng'),
      ('Español / Spanish (Latin America)', 'spa'),
      ('Deutsch SDH', 'deu'),
      ('pt-BR', 'por'),
      ('Chinese (Simplified)', 'zho'),
      ('日本語 / Japanese', 'jpn'),
      ('uk', 'ukr'),
    ]) {
      expect(
        canonicalCaptionLanguageCode(testCase.$1),
        testCase.$2,
        reason: testCase.$1,
      );
    }
  });

  test('unsafe caption language values fail closed', () {
    expect(canonicalCaptionLanguageCode('../eng', fallback: 'eng'), 'eng');
    expect(canonicalCaptionLanguageCode('', fallback: 'eng'), 'eng');
    expect(captionLanguageDisplayName('spa'), 'Spanish');
  });
}
