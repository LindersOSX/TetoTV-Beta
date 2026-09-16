import 'package:flutter/widgets.dart';

/// Interface choices are deliberately separate from metadata title languages.
enum AppLanguage {
  english('en', 'English', 'eng'),
  spanish('es', 'Español', 'spa'),
  portuguese('pt', 'Português', 'por'),
  french('fr', 'Français', 'fra'),
  hindi('hi', 'हिन्दी', 'hin'),
  german('de', 'Deutsch', 'deu');

  const AppLanguage(this.code, this.nativeName, this.mediaLanguage);
  final String code;

  /// Autonym for language pickers; render verbatim, never through translation.
  final String nativeName;
  final String mediaLanguage;
  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) {
    final base = code?.toLowerCase().split(RegExp('[-_]')).first;
    return values.firstWhere(
      (language) => language.code == base,
      orElse: () => english,
    );
  }
}
