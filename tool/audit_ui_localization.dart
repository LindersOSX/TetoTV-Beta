// Read-only UI translation coverage audit; see docs/LOCALIZATION.md.
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:anime_tv/core/localization/catalogs/aniyomi_strings.dart';
import 'package:anime_tv/core/localization/catalogs/common_strings.dart';
import 'package:anime_tv/core/localization/catalogs/experimental_features_strings.dart';
import 'package:anime_tv/core/localization/catalogs/home_strings.dart';
import 'package:anime_tv/core/localization/catalogs/library_strings.dart';
import 'package:anime_tv/core/localization/catalogs/manga_reader_strings.dart';
import 'package:anime_tv/core/localization/catalogs/manga_backup_strings.dart';
import 'package:anime_tv/core/localization/catalogs/manga_library_strings.dart';
import 'package:anime_tv/core/localization/catalogs/manga_tracking_strings.dart';
import 'package:anime_tv/core/localization/catalogs/playback_strings.dart';
import 'package:anime_tv/core/localization/catalogs/settings_strings.dart';

void main(List<String> args) {
  final audit = auditUiLocalizations();
  for (final entry in audit.missing.entries) {
    print('MISSING ${entry.key}\n  ${entry.value.join("\n  ")}');
  }
  if (args.contains('--raw')) {
    for (final item in audit.raw) {
      print('RAW $item');
    }
  }
  print(
    'Catalog keys (including uppercase aliases): ${audit.keyCount}. Missing literal messages: ${audit.missing.length}. Raw Text literals: ${audit.raw.length}.',
  );
  if (audit.missing.isNotEmpty || audit.raw.isNotEmpty) exitCode = 1;
}

({Map<String, Set<String>> missing, List<String> raw, int keyCount})
auditUiLocalizations() {
  final catalogs = [
    aniyomiTranslations,
    commonTranslations,
    experimentalFeaturesTranslations,
    homeTranslations,
    libraryTranslations,
    mangaReaderTranslations,
    mangaBackupTranslations,
    mangaLibraryTranslations,
    mangaTrackingTranslations,
    playbackTranslations,
    settingsTranslations,
  ];
  final keys = <String>{for (final c in catalogs) ...c['es']!.keys};
  keys.addAll(
    keys
        .where((key) => !key.contains('{'))
        .map((key) => key.toUpperCase())
        .toList(),
  );
  final missing = <String, Set<String>>{};
  final raw = <String>[];
  for (final file in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart') || file.path.contains('localization')) {
      continue;
    }
    final result = parseString(
      content: file.readAsStringSync(),
      path: file.path,
    );
    result.unit.accept(
      _Audit((node, source, translated) {
        if (!RegExp(r'[a-zA-Z]{2}').hasMatch(source)) return;
        final where =
            '${file.path}:${result.lineInfo.getLocation(node.offset).lineNumber}';
        if (translated) {
          if (!keys.contains(source) &&
              !_unchangedLabels.contains(source) &&
              !source.startsWith('http') &&
              !source.startsWith('stremio://')) {
            (missing[source] ??= {}).add(where);
          }
        } else if (!_unchangedLabels.contains(source)) {
          raw.add('$where: $source');
        }
      }),
    );
  }
  return (missing: missing, raw: raw, keyCount: keys.length);
}

// Protocol names, examples, units, brands and copyright attribution stay exact.
const _unchangedLabels = {
  'Teto',
  'TV',
  'TetoTV',
  'Teto TV',
  'SIMKL',
  'CC',
  'MPV',
  'API',
  'URL',
  'EN: {value1}',
  'MAL',
  'HEVC',
  'AV1',
  'HDR',
  'X-Plex-Token',
  '{value1}/s',
  '{value1} • {value2} • Jellyfin {value3}',
  '{value1} • Plex {value2}',
  '192.168.1.20:8096 or https://jellyfin.example.com',
  '192.168.1.20:32400 or https://plex.example.com',
  '重音テト © 線 / 小山乃舞世 / TWINDRILL',
};

class _Audit extends RecursiveAstVisitor<void> {
  _Audit(this.report);
  final void Function(AstNode, String, bool) report;
  void check(String name, ArgumentList arguments, AstNode node) {
    if (!{'tr', 'LocalizedText', 'Text', 'SelectableText'}.contains(name) ||
        arguments.arguments.isEmpty) {
      return;
    }
    final first = arguments.arguments.first;
    if (first is StringLiteral && first.stringValue != null) {
      report(node, first.stringValue!, name == 'tr' || name == 'LocalizedText');
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    check(node.constructorName.type.name.lexeme, node.argumentList, node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    check(node.methodName.name, node.argumentList, node);
    super.visitMethodInvocation(node);
  }
}
