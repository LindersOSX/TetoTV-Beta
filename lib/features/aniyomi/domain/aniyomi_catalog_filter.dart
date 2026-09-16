import 'aniyomi_repository_models.dart';

/// Catalog-only language grouping. Regional tags such as pt-BR/pt-PT share
/// one picker option; the original repository metadata remains untouched.
String aniyomiCatalogLanguageCode(String value) {
  final normalized = value.trim().toLowerCase().replaceAll('_', '-');
  if (normalized.isEmpty || normalized == 'unknown') return 'unknown';
  if (normalized == 'all' || normalized == 'multi') return 'all';
  return normalized.split('-').first;
}

/// A multilingual APK can declare individual source languages. Include those
/// without assuming that an unspecified `all` source supports every language.
Set<String> aniyomiCatalogExtensionLanguages(
  AniyomiRepositoryExtension extension,
) => {
  aniyomiCatalogLanguageCode(extension.language),
  for (final source in extension.sources)
    aniyomiCatalogLanguageCode(source.language),
};

List<String> aniyomiCatalogLanguages(
  Iterable<AniyomiRepositoryExtension> catalog, {
  required bool mangaEnabled,
}) =>
    catalog
        .where(
          (extension) =>
              mangaEnabled || extension.kind != AniyomiMediaKind.manga,
        )
        .expand(aniyomiCatalogExtensionLanguages)
        .toSet()
        .toList()
      ..sort();

/// Filtering is a local view only: no installation, approval, source discovery,
/// playback language, or persisted preference is changed here.
List<AniyomiRepositoryExtension> filterAniyomiCatalog(
  Iterable<AniyomiRepositoryExtension> catalog, {
  required bool mangaEnabled,
  String? language,
  String query = '',
}) {
  final selected = language == null
      ? null
      : aniyomiCatalogLanguageCode(language);
  final search = query.trim().toLowerCase();
  return catalog
      .where((extension) {
        if (!mangaEnabled && extension.kind == AniyomiMediaKind.manga) {
          return false;
        }
        if (selected != null &&
            !aniyomiCatalogExtensionLanguages(extension).contains(selected)) {
          return false;
        }
        return search.isEmpty ||
            '${extension.name} ${extension.language} ${extension.sources.map((source) => '${source.name} ${source.language}').join(' ')}'
                .toLowerCase()
                .contains(search);
      })
      .toList(growable: false);
}
