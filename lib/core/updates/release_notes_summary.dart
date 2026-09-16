/// Customer-facing display policy only. Never use this to parse or validate a
/// release: the updater must retain the original body and its integrity markers.
List<String> customerReleaseHighlights(
  String notes, {
  int maximumItems = 6,
  int maximumItemLength = 180,
}) {
  final itemLimit = maximumItems.clamp(0, 6);
  final characterLimit = maximumItemLength.clamp(40, 180);
  if (itemLimit == 0) return const [];
  var source = notes.length > 65536 ? notes.substring(0, 65536) : notes;
  source = _decodeReleaseEntities(source)
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
      .replaceAll(RegExp(r'<\s*!\s*-+[\s\S]*?(?:--\s*>|$)'), '')
      .replaceAll(
        RegExp(r'<details\b[\s\S]*?(?:</details>|$)', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
  final lines = source.split(RegExp(r'\r?\n'));
  final preferred = <String>[];
  final fallback = <String>[];
  final warnings = <String>[];
  var section = 'fallback';
  var sectionLevel = 0;
  var hasPreferred = false;
  var alert = false;
  var metadataContinuation = false;
  String? fence;
  final paragraph = <String>[];

  void flush() {
    final text = _plainReleaseItem(paragraph.join(' '));
    paragraph.clear();
    if (text.isEmpty || _engineeringItem(text)) return;
    if (alert && section != 'excluded') {
      warnings.add(text);
      return;
    }
    switch (section) {
      case 'preferred':
        preferred.add(text);
      case 'warning':
        warnings.add(text);
      case 'fallback':
        fallback.add(text);
    }
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line.startsWith('```') || line.startsWith('~~~')) {
      flush();
      final marker = line.substring(0, 3);
      if (fence == null) {
        fence = marker;
      } else if (fence == marker) {
        fence = null;
      }
      continue;
    }
    if (fence != null) continue;
    final heading = RegExp(r'^(#{1,6})\s+(.+?)\s*#*$').firstMatch(line);
    final boldHeading = RegExp(r'^\*\*([^*]+)\*\*:?$').firstMatch(line);
    final setext =
        i + 1 < lines.length &&
        RegExp(r'^(?:={3,}|-{3,})$').hasMatch(lines[i + 1].trim()) &&
        line.isNotEmpty;
    if (heading != null || boldHeading != null || setext) {
      flush();
      alert = false;
      metadataContinuation = false;
      final label = (heading?.group(2) ?? boldHeading?.group(1) ?? line)
          .toLowerCase()
          .replaceAll('’', "'")
          .replaceAll(RegExp(r'[:*_`]+'), '')
          .trim();
      final level = heading?.group(1)?.length ?? 2;
      final preferredHeading = RegExp(
        r"^(?:highlights|what's new|what's changed|what changed|new in this (?:update|release)|changes)$",
      ).hasMatch(label);
      final warningHeading = RegExp(
        r'^(?:known (?:issues?|limitations?)|warnings?|cautions?|important(?: .*)?|before (?:you )?updat(?:e|ing))$',
      ).hasMatch(label);
      final excludedHeading = RegExp(
        r'^(?:install|installation|download|verification|testing|technical|developer|development|build|license|licensing|legal|source code|checksums|credits|ai disclosure|release metadata)\b',
      ).hasMatch(label);
      if (preferredHeading) {
        section = 'preferred';
        sectionLevel = level;
        hasPreferred = true;
      } else if (warningHeading) {
        section = 'warning';
        sectionLevel = level;
      } else if (excludedHeading) {
        section = 'excluded';
        sectionLevel = level;
      } else if (level <= sectionLevel || sectionLevel == 0) {
        section = 'fallback';
        sectionLevel = level;
      }
      if (setext) i++;
      continue;
    }
    if (line.isEmpty || RegExp(r'^[-*_]{3,}$').hasMatch(line)) {
      flush();
      alert = false;
      metadataContinuation = false;
      continue;
    }
    if (RegExp(
      r'^>\s*\[!(?:WARNING|CAUTION|IMPORTANT)\]',
      caseSensitive: false,
    ).hasMatch(line)) {
      flush();
      alert = true;
      continue;
    }
    if (line.startsWith('>')) {
      if (!alert) continue;
      line = line.replaceFirst(RegExp(r'^>\s?'), '');
    } else if (alert) {
      flush();
      alert = false;
    }
    final bullet = RegExp(
      r'^(?:[-*+•]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.+)$',
    ).firstMatch(line);
    if (bullet != null) {
      flush();
      metadataContinuation = false;
      line = bullet.group(1)!;
    }
    // Drop malformed/legacy markers and their wrapped payloads as well as
    // intact comments. This is display filtering, not release validation.
    if (RegExp(
      r'\btetotv[-_][a-z0-9_-]+\s*[:=]|^\s*(?:signature|attestation|sha256|sha512|checksum|base64)\s*[:=]',
      caseSensitive: false,
    ).hasMatch(line)) {
      flush();
      metadataContinuation = true;
      continue;
    }
    if (metadataContinuation ||
        RegExp(r'^\[[^\]]+\]:').hasMatch(line) ||
        RegExp(
          r'tetotv[-_](?:android|native|unreviewed|license)|sha-?256|sha256sums',
          caseSensitive: false,
        ).hasMatch(line) ||
        RegExp(r'^[A-Za-z0-9+/=_\[\]-]{80,}$').hasMatch(line)) {
      flush();
      continue;
    }
    paragraph.add(line);
  }
  flush();
  final seen = <String>{};
  final result = <String>[];
  // Known customer limitations must not be crowded out by a long feature list.
  for (final item in [...warnings, ...(hasPreferred ? preferred : fallback)]) {
    if (!seen.add(item.toLowerCase())) continue;
    result.add(_shortReleaseItem(item, characterLimit));
    if (result.length >= itemLimit) break;
  }
  return List.unmodifiable(result);
}

String formatCustomerReleaseNotes(
  String notes, {
  int maximumItems = 6,
  int maximumItemLength = 180,
}) => customerReleaseHighlights(
  notes,
  maximumItems: maximumItems,
  maximumItemLength: maximumItemLength,
).map((item) => '• $item').join('\n');

String _decodeReleaseEntities(String value) => value.replaceAllMapped(
  RegExp(
    r'&(?:#(x[0-9a-f]+|\d+)|(amp|lt|gt|quot|apos|nbsp));',
    caseSensitive: false,
  ),
  (match) {
    final numeric = match.group(1)?.toLowerCase();
    if (numeric != null) {
      final code = int.tryParse(
        numeric.startsWith('x') ? numeric.substring(1) : numeric,
        radix: numeric.startsWith('x') ? 16 : 10,
      );
      return code != null && code > 0 && code <= 0x10ffff
          ? String.fromCharCode(code)
          : '';
    }
    return const {
          'amp': '&',
          'lt': '<',
          'gt': '>',
          'quot': '"',
          'apos': "'",
          'nbsp': ' ',
        }[match.group(2)?.toLowerCase()] ??
        match.group(0)!;
  },
);

String _plainReleaseItem(String text) => text
    .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
    .replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]*\)'),
      (match) => match.group(1)!,
    )
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '')
    .replaceAll(RegExp(r'[A-Za-z0-9+/=_-]{96,}'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'[*_`~]+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _engineeringItem(String text) =>
    RegExp(
      r'^(?:ai (?:tools|assisted)|automated (?:checks|tests)|(?:focused|unit|widget|integration|regression|native).{0,100}tests? (?:passed|pass)|beta only|android build|no public apk|no repository|no independent native)',
      caseSensitive: false,
    ).hasMatch(text) ||
    RegExp(
      r'native-playback-sources|native-license review|tetotv[-_](?:android|native|unreviewed|license)|sha256sums',
      caseSensitive: false,
    ).hasMatch(text);

String _shortReleaseItem(String text, int maximum) {
  if (text.length <= maximum) return text;
  var end = maximum - 1;
  final space = text.lastIndexOf(' ', end);
  if (space >= maximum ~/ 2) end = space;
  final unit = text.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  return '${text.substring(0, end).trimRight()}…';
}
