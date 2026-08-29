import 'package:anime_tv/features/catalog/domain/anime_summary.dart';

enum FranchiseRelationRole {
  current,
  prequel,
  sequel,
  spinOff,
  sideStory,
  alternative,
  summary,
  adaptation,
  other,
}

class FranchiseWatchOrderEntry {
  const FranchiseWatchOrderEntry({
    required this.anime,
    required this.relationRole,
  });

  final AnimeSummary anime;
  final FranchiseRelationRole relationRole;

  String get relationLabel => switch (relationRole) {
    FranchiseRelationRole.current => 'Current',
    FranchiseRelationRole.prequel => 'Prequel',
    FranchiseRelationRole.sequel => 'Sequel',
    FranchiseRelationRole.spinOff => 'Spin-off',
    FranchiseRelationRole.sideStory => 'Side story',
    FranchiseRelationRole.alternative => 'Alternative',
    FranchiseRelationRole.summary => 'Summary',
    FranchiseRelationRole.adaptation => 'Adaptation',
    FranchiseRelationRole.other => 'Related',
  };

  String get formatLabel => switch (_normalized(anime.format)) {
    'MOVIE' => 'Movie',
    'OVA' => 'OVA',
    'SPECIAL' => 'Special',
    'ONA' => 'ONA',
    'TV SHORT' => 'TV short',
    'TV' => 'TV',
    final value when value.isNotEmpty => _titleCase(value),
    _ => 'Anime',
  };

  String get watchOrderLabel => '$formatLabel · $relationLabel';
}

/// Builds a deterministic, cycle-safe watch order from AniList relations.
///
/// Continuation relations define the primary path. Side stories, spin-offs,
/// summaries, and alternatives are placed after the title which references
/// them. Release metadata is used only as a stable tie-breaker, so a sequel is
/// never moved ahead of its known prequel merely because one date is missing.
List<FranchiseWatchOrderEntry> buildRecommendedFranchiseWatchOrder({
  required int rootId,
  required Iterable<AnimeSummary> anime,
}) {
  final sources = anime.toList(growable: false);
  final byId = <int, AnimeSummary>{};
  for (final item in sources) {
    _rememberBestSummary(byId, item);
    for (final relation in item.relatedAnime) {
      _rememberBestSummary(byId, relation.anime);
    }
  }
  if (byId.isEmpty) return const [];

  final orderEdges = <int, Set<int>>{for (final id in byId.keys) id: <int>{}};
  final continuationEdges = <int, Set<int>>{
    for (final id in byId.keys) id: <int>{},
  };
  final directRootRelations = <int, String>{};
  final relationHints = <int, Set<String>>{};

  void addEdge(Map<int, Set<int>> graph, int from, int to) {
    if (from != to && graph.containsKey(from) && graph.containsKey(to)) {
      graph[from]!.add(to);
    }
  }

  for (final source in sources) {
    if (!byId.containsKey(source.id)) continue;
    for (final related in source.relatedAnime) {
      final targetId = related.anime.id;
      if (!byId.containsKey(targetId) || targetId == source.id) continue;
      final relation = _normalized(related.relationType);
      relationHints.putIfAbsent(targetId, () => <String>{}).add(relation);
      if (source.id == rootId) directRootRelations[targetId] = relation;

      switch (relation) {
        case 'SEQUEL':
          addEdge(orderEdges, source.id, targetId);
          addEdge(continuationEdges, source.id, targetId);
        case 'PREQUEL':
        case 'PARENT':
          addEdge(orderEdges, targetId, source.id);
          addEdge(continuationEdges, targetId, source.id);
        case 'SIDE STORY':
        case 'SPIN OFF':
        case 'SUMMARY':
        case 'ALTERNATIVE':
        case 'COMPILATION':
        case 'CONTAINS':
          addEdge(orderEdges, source.id, targetId);
      }
    }
  }

  final successors = _reachableFrom(rootId, continuationEdges);
  final reverseContinuation = <int, Set<int>>{
    for (final id in byId.keys) id: <int>{},
  };
  for (final entry in continuationEdges.entries) {
    for (final target in entry.value) {
      reverseContinuation[target]!.add(entry.key);
    }
  }
  final predecessors = _reachableFrom(rootId, reverseContinuation);

  FranchiseRelationRole roleFor(int id) {
    if (id == rootId) return FranchiseRelationRole.current;
    final direct = directRootRelations[id];
    final directRole = _roleForDirectRelation(direct);
    if (directRole != null && directRole != FranchiseRelationRole.other) {
      return directRole;
    }
    if (predecessors.contains(id)) return FranchiseRelationRole.prequel;
    if (successors.contains(id)) return FranchiseRelationRole.sequel;
    final hints = relationHints[id] ?? const <String>{};
    for (final relation in const [
      'SPIN OFF',
      'SIDE STORY',
      'SUMMARY',
      'ALTERNATIVE',
      'ADAPTATION',
      'SOURCE',
    ]) {
      if (hints.contains(relation)) {
        return _roleForDirectRelation(relation) ?? FranchiseRelationRole.other;
      }
    }
    return directRole ?? FranchiseRelationRole.other;
  }

  final roleById = <int, FranchiseRelationRole>{
    for (final id in byId.keys) id: roleFor(id),
  };
  final orderedIds = _stableTopologicalOrder(
    byId: byId,
    edges: orderEdges,
    roleById: roleById,
  );
  return List.unmodifiable([
    for (final id in orderedIds)
      FranchiseWatchOrderEntry(anime: byId[id]!, relationRole: roleById[id]!),
  ]);
}

void _rememberBestSummary(Map<int, AnimeSummary> byId, AnimeSummary candidate) {
  final current = byId[candidate.id];
  if (current == null ||
      (current.relatedAnime.isEmpty && candidate.relatedAnime.isNotEmpty)) {
    byId[candidate.id] = candidate;
  }
}

Set<int> _reachableFrom(int start, Map<int, Set<int>> graph) {
  if (!graph.containsKey(start)) return const <int>{};
  final reached = <int>{};
  final pending = <int>[start];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    for (final target in graph[current] ?? const <int>{}) {
      if (target != start && reached.add(target)) pending.add(target);
    }
  }
  return reached;
}

List<int> _stableTopologicalOrder({
  required Map<int, AnimeSummary> byId,
  required Map<int, Set<int>> edges,
  required Map<int, FranchiseRelationRole> roleById,
}) {
  final remaining = byId.keys.toSet();
  final incoming = <int, int>{for (final id in remaining) id: 0};
  for (final targets in edges.values) {
    for (final target in targets) {
      incoming[target] = (incoming[target] ?? 0) + 1;
    }
  }

  int compareIds(int left, int right) {
    final a = byId[left]!;
    final b = byId[right]!;
    final year = (a.seasonYear ?? 9999).compareTo(b.seasonYear ?? 9999);
    if (year != 0) return year;
    final season = _seasonRank(a.season).compareTo(_seasonRank(b.season));
    if (season != 0) return season;
    final role = _roleRank(
      roleById[left]!,
    ).compareTo(_roleRank(roleById[right]!));
    if (role != 0) return role;
    return left.compareTo(right);
  }

  final result = <int>[];
  while (remaining.isNotEmpty) {
    final ready = remaining.where((id) => incoming[id] == 0).toList()
      ..sort(compareIds);
    // AniList data can contain reciprocal or malformed relation cycles. Pick
    // a deterministic release-order anchor and remove its incoming cycle
    // edges rather than omitting the entire connected component.
    final next = ready.isNotEmpty
        ? ready.first
        : (remaining.toList()..sort(compareIds)).first;
    remaining.remove(next);
    result.add(next);
    for (final target in edges[next] ?? const <int>{}) {
      if (remaining.contains(target)) {
        incoming[target] = (incoming[target] ?? 1) - 1;
      }
    }
  }
  return result;
}

FranchiseRelationRole? _roleForDirectRelation(String? relation) =>
    switch (relation) {
      'PREQUEL' || 'PARENT' => FranchiseRelationRole.prequel,
      'SEQUEL' => FranchiseRelationRole.sequel,
      'SPIN OFF' => FranchiseRelationRole.spinOff,
      'SIDE STORY' => FranchiseRelationRole.sideStory,
      'ALTERNATIVE' => FranchiseRelationRole.alternative,
      'SUMMARY' || 'COMPILATION' => FranchiseRelationRole.summary,
      'ADAPTATION' || 'SOURCE' => FranchiseRelationRole.adaptation,
      null => null,
      _ => FranchiseRelationRole.other,
    };

int _seasonRank(String? season) => switch (_normalized(season)) {
  'WINTER' => 0,
  'SPRING' => 1,
  'SUMMER' => 2,
  'FALL' => 3,
  _ => 4,
};

int _roleRank(FranchiseRelationRole role) => switch (role) {
  FranchiseRelationRole.prequel => 0,
  FranchiseRelationRole.current => 1,
  FranchiseRelationRole.sequel => 2,
  FranchiseRelationRole.sideStory => 3,
  FranchiseRelationRole.spinOff => 4,
  FranchiseRelationRole.summary => 5,
  FranchiseRelationRole.alternative => 6,
  FranchiseRelationRole.adaptation => 7,
  FranchiseRelationRole.other => 8,
};

String _normalized(String? value) =>
    value
        ?.trim()
        .toUpperCase()
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ') ??
    '';

String _titleCase(String value) => value
    .toLowerCase()
    .split(' ')
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');
