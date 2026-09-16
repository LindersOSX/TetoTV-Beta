import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, Intl;
import 'package:intl/date_symbol_data_local.dart' show initializeDateFormatting;

import 'app_language.dart';
import 'catalogs/aniyomi_strings.dart';
import 'catalogs/common_strings.dart';
import 'catalogs/home_strings.dart';
import 'catalogs/library_strings.dart';
import 'catalogs/manga_reader_strings.dart';
import 'catalogs/manga_backup_strings.dart';
import 'catalogs/manga_library_strings.dart';
import 'catalogs/manga_tracking_strings.dart';
import 'catalogs/playback_strings.dart';
import 'catalogs/settings_strings.dart';

/// Only app-authored UI messages enter this catalog. Never translate media
/// titles, usernames, provider responses, URLs, stored IDs, logs, or user text.
class TetoLocalizations {
  const TetoLocalizations(this.language);
  final AppLanguage language;

  static const delegate = _TetoLocalizationsDelegate();
  static final supportedLocales = [
    for (final value in AppLanguage.values) value.locale,
  ];
  static final catalogs = <Map<String, Map<String, String>>>[
    aniyomiTranslations,
    commonTranslations,
    homeTranslations,
    libraryTranslations,
    mangaReaderTranslations,
    mangaBackupTranslations,
    mangaLibraryTranslations,
    mangaTrackingTranslations,
    playbackTranslations,
    settingsTranslations,
  ];
  static final _messages = <String, Map<String, String>>{
    for (final language in AppLanguage.values)
      language.code: {
        for (final catalog in catalogs) ...?catalog[language.code],
      },
  };

  // Small uppercase headings share the same catalog as their normal labels.
  // Only known app strings receive this alias, never arbitrary media/user text.
  static final _uppercaseMessages = <String, Map<String, String>>{
    for (final entry in _messages.entries)
      entry.key: {
        for (final message in entry.value.entries)
          if (!message.key.contains('{'))
            message.key.toUpperCase(): message.value.toUpperCase(),
      },
  };

  static TetoLocalizations of(BuildContext context) =>
      Localizations.of<TetoLocalizations>(context, TetoLocalizations) ??
      TetoLocalizations(
        AppLanguage.fromCode(
          Localizations.maybeLocaleOf(context)?.languageCode,
        ),
      );

  /// Named placeholders let each language reorder a complete sentence. Values
  /// are inserted once, without interpreting or translating their contents.
  String text(String source, [Map<String, Object> arguments = const {}]) {
    final translated =
        _messages[language.code]?[source] ??
        _uppercaseMessages[language.code]?[source] ??
        source;
    return translated.replaceAllMapped(RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}'), (
      match,
    ) {
      final value = arguments[match[1]];
      return value?.toString() ?? match[0]!;
    });
  }

  String plural(int count, {required String one, required String other}) =>
      text(
        Intl.pluralLogic(count, locale: language.code, one: one, other: other),
        {'count': count},
      );

  static bool _dateDataReady = false;
  void _ensureDateData() {
    if (_dateDataReady) return;
    // The local-data implementation registers its bundled tables synchronously
    // before returning a completed future. No network or deferred file I/O.
    initializeDateFormatting().ignore();
    _dateDataReady = true;
  }

  String date(DateTime value, {bool short = false, bool localTime = true}) {
    _ensureDateData();
    return (short
            ? DateFormat.yMMMd(language.code)
            : DateFormat.yMMMMd(language.code))
        .format(localTime ? value.toLocal() : value);
  }

  String weekdayDate(DateTime value) {
    _ensureDateData();
    return DateFormat.MMMEd(language.code).format(value.toLocal());
  }
}

class _TetoLocalizationsDelegate
    extends LocalizationsDelegate<TetoLocalizations> {
  const _TetoLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) =>
      AppLanguage.values.any((value) => value.code == locale.languageCode);
  @override
  Future<TetoLocalizations> load(Locale locale) => SynchronousFuture(
    TetoLocalizations(AppLanguage.fromCode(locale.languageCode)),
  );
  @override
  bool shouldReload(_TetoLocalizationsDelegate old) => false;
}

extension TetoTranslationContext on BuildContext {
  String tr(String source, [Map<String, Object> arguments = const {}]) =>
      TetoLocalizations.of(this).text(source, arguments);
}

/// Const-friendly UI text. Use ordinary [Text] for external content. This
/// wrapper subscribes to Localizations so const subtrees update on a change.
class LocalizedText extends StatelessWidget {
  const LocalizedText(
    this.data, {
    super.key,
    this.arguments = const {},
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });
  final String data;
  final Map<String, Object> arguments;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final double? textScaleFactor;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) => Text(
    context.tr(data, arguments),
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler:
        textScaler ??
        (textScaleFactor == null ? null : TextScaler.linear(textScaleFactor!)),
    maxLines: maxLines,
    semanticsLabel: semanticsLabel == null
        ? null
        : context.tr(semanticsLabel!, arguments),
    semanticsIdentifier: semanticsIdentifier,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    selectionColor: selectionColor,
  );
}
