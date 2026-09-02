/// A caption language exposed by the Playback settings screen.
class CaptionLanguageOption {
  const CaptionLanguageOption({
    required this.code,
    required this.label,
    this.aliases = const [],
  });

  /// Canonical ISO 639-2 code persisted by TetoTV.
  final String code;
  final String label;
  final List<String> aliases;
}

/// Common subtitle languages offered by streaming providers and media servers.
///
/// Settings write these canonical ISO 639-2 codes. Existing two-letter ISO
/// values remain readable so older installs do not need a storage migration.
const preferredCaptionLanguageOptions = <CaptionLanguageOption>[
  CaptionLanguageOption(
    code: 'eng',
    label: 'English',
    aliases: ['en', 'english'],
  ),
  CaptionLanguageOption(
    code: 'spa',
    label: 'Spanish',
    aliases: ['es', 'spanish'],
  ),
  CaptionLanguageOption(
    code: 'ita',
    label: 'Italian',
    aliases: ['it', 'italian'],
  ),
  CaptionLanguageOption(
    code: 'jpn',
    label: 'Japanese',
    aliases: ['ja', 'jp', 'japanese'],
  ),
  CaptionLanguageOption(
    code: 'fra',
    label: 'French',
    aliases: ['fr', 'fre', 'french'],
  ),
  CaptionLanguageOption(
    code: 'por',
    label: 'Portuguese',
    aliases: ['pt', 'portuguese', 'brazilian portuguese'],
  ),
  CaptionLanguageOption(
    code: 'ara',
    label: 'Arabic',
    aliases: ['ar', 'arabic'],
  ),
  CaptionLanguageOption(
    code: 'ben',
    label: 'Bengali',
    aliases: ['bn', 'bengali', 'bangla'],
  ),
  CaptionLanguageOption(
    code: 'bul',
    label: 'Bulgarian',
    aliases: ['bg', 'bulgarian'],
  ),
  CaptionLanguageOption(
    code: 'cat',
    label: 'Catalan',
    aliases: ['ca', 'catalan'],
  ),
  CaptionLanguageOption(
    code: 'zho',
    label: 'Chinese',
    aliases: ['zh', 'chi', 'chinese', 'mandarin'],
  ),
  CaptionLanguageOption(
    code: 'hrv',
    label: 'Croatian',
    aliases: ['hr', 'croatian'],
  ),
  CaptionLanguageOption(
    code: 'ces',
    label: 'Czech',
    aliases: ['cs', 'cze', 'czech'],
  ),
  CaptionLanguageOption(
    code: 'dan',
    label: 'Danish',
    aliases: ['da', 'danish'],
  ),
  CaptionLanguageOption(
    code: 'nld',
    label: 'Dutch',
    aliases: ['nl', 'dut', 'dutch'],
  ),
  CaptionLanguageOption(
    code: 'fin',
    label: 'Finnish',
    aliases: ['fi', 'finnish'],
  ),
  CaptionLanguageOption(
    code: 'deu',
    label: 'German',
    aliases: ['de', 'ger', 'german', 'deutsch'],
  ),
  CaptionLanguageOption(
    code: 'ell',
    label: 'Greek',
    aliases: ['el', 'gre', 'greek'],
  ),
  CaptionLanguageOption(
    code: 'heb',
    label: 'Hebrew',
    aliases: ['he', 'iw', 'hebrew'],
  ),
  CaptionLanguageOption(code: 'hin', label: 'Hindi', aliases: ['hi', 'hindi']),
  CaptionLanguageOption(
    code: 'hun',
    label: 'Hungarian',
    aliases: ['hu', 'hungarian'],
  ),
  CaptionLanguageOption(
    code: 'ind',
    label: 'Indonesian',
    aliases: ['id', 'indonesian', 'bahasa indonesia'],
  ),
  CaptionLanguageOption(
    code: 'kor',
    label: 'Korean',
    aliases: ['ko', 'korean'],
  ),
  CaptionLanguageOption(
    code: 'msa',
    label: 'Malay',
    aliases: ['ms', 'may', 'malay'],
  ),
  CaptionLanguageOption(
    code: 'nor',
    label: 'Norwegian',
    aliases: ['no', 'nb', 'nn', 'norwegian'],
  ),
  CaptionLanguageOption(
    code: 'fas',
    label: 'Persian',
    aliases: ['fa', 'per', 'persian', 'farsi'],
  ),
  CaptionLanguageOption(
    code: 'pol',
    label: 'Polish',
    aliases: ['pl', 'polish'],
  ),
  CaptionLanguageOption(
    code: 'ron',
    label: 'Romanian',
    aliases: ['ro', 'rum', 'romanian'],
  ),
  CaptionLanguageOption(
    code: 'rus',
    label: 'Russian',
    aliases: ['ru', 'russian'],
  ),
  CaptionLanguageOption(
    code: 'srp',
    label: 'Serbian',
    aliases: ['sr', 'serbian'],
  ),
  CaptionLanguageOption(
    code: 'slk',
    label: 'Slovak',
    aliases: ['sk', 'slo', 'slovak'],
  ),
  CaptionLanguageOption(
    code: 'slv',
    label: 'Slovenian',
    aliases: ['sl', 'slovenian'],
  ),
  CaptionLanguageOption(
    code: 'swe',
    label: 'Swedish',
    aliases: ['sv', 'swedish'],
  ),
  CaptionLanguageOption(
    code: 'fil',
    label: 'Tagalog / Filipino',
    aliases: ['tl', 'tagalog', 'filipino'],
  ),
  CaptionLanguageOption(code: 'tam', label: 'Tamil', aliases: ['ta', 'tamil']),
  CaptionLanguageOption(
    code: 'tel',
    label: 'Telugu',
    aliases: ['te', 'telugu'],
  ),
  CaptionLanguageOption(code: 'tha', label: 'Thai', aliases: ['th', 'thai']),
  CaptionLanguageOption(
    code: 'tur',
    label: 'Turkish',
    aliases: ['tr', 'turkish'],
  ),
  CaptionLanguageOption(
    code: 'ukr',
    label: 'Ukrainian',
    aliases: ['uk', 'ukrainian'],
  ),
  CaptionLanguageOption(code: 'urd', label: 'Urdu', aliases: ['ur', 'urdu']),
  CaptionLanguageOption(
    code: 'vie',
    label: 'Vietnamese',
    aliases: ['vi', 'vietnamese'],
  ),
];

/// Normalizes provider labels, ISO aliases, and locale tags to an ISO 639-2
/// code. Unknown short ISO codes remain usable for forward compatibility.
String canonicalCaptionLanguageCode(String? value, {String fallback = ''}) {
  final normalized = (value ?? '')
      .trim()
      .toLowerCase()
      .replaceAll('_', '-')
      .replaceAll(RegExp(r'[^a-z-]+'), ' ')
      .trim();
  if (normalized.isEmpty) return fallback;

  final direct = normalized.replaceAll(' ', '-');
  final base = direct.split('-').first;
  for (final option in preferredCaptionLanguageOptions) {
    if (direct == option.code || base == option.code) return option.code;
    for (final alias in option.aliases) {
      final normalizedAlias = alias.replaceAll(' ', '-');
      if (direct == normalizedAlias || base == normalizedAlias) {
        return option.code;
      }
    }
  }

  final words = ' ${normalized.replaceAll('-', ' ')} ';
  for (final option in preferredCaptionLanguageOptions) {
    for (final alias in [option.label.toLowerCase(), ...option.aliases]) {
      final phrase = alias.replaceAll('-', ' ').trim();
      if (phrase.length > 2 && words.contains(' $phrase ')) {
        return option.code;
      }
    }
  }

  return RegExp(r'^[a-z]{2,3}$').hasMatch(direct) ? direct : fallback;
}

String captionLanguageDisplayName(String code) {
  final canonical = canonicalCaptionLanguageCode(code);
  for (final option in preferredCaptionLanguageOptions) {
    if (option.code == canonical) return option.label;
  }
  return canonical.isEmpty ? 'English' : canonical.toUpperCase();
}
