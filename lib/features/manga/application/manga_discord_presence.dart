import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class MangaDiscordPresencePlatform {
  Future<void> updateReading({
    required String title,
    required String chapterLabel,
    required int page,
    required int pageCount,
  });

  Future<void> clear();
}

class AndroidMangaDiscordPresencePlatform
    implements MangaDiscordPresencePlatform {
  AndroidMangaDiscordPresencePlatform(this._bridge);

  final AndroidTvBridge _bridge;

  @override
  Future<void> updateReading({
    required String title,
    required String chapterLabel,
    required int page,
    required int pageCount,
  }) => _bridge.updateDiscordReadingPresence(
    title: title,
    chapterLabel: chapterLabel,
    page: page,
    pageCount: pageCount,
  );

  @override
  Future<void> clear() => _bridge.clearDiscordPresence();
}

final mangaDiscordPresencePlatformProvider =
    Provider<MangaDiscordPresencePlatform>(
      (_) => AndroidMangaDiscordPresencePlatform(AndroidTvBridge.instance),
    );

final mangaDiscordPresenceCoordinatorProvider =
    Provider<MangaDiscordPresenceCoordinator>((ref) {
      final coordinator = MangaDiscordPresenceCoordinator(
        ref.watch(mangaDiscordPresencePlatformProvider),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

/// Coalesces page changes so scrubbing through a chapter cannot flood Discord.
///
/// A new title/chapter is published immediately. Page-only movement is sent at
/// most once per [minimumPageInterval], with the newest page winning.
class MangaDiscordPresenceCoordinator {
  MangaDiscordPresenceCoordinator(
    this._platform, {
    this.minimumPageInterval = const Duration(seconds: 15),
  });

  final MangaDiscordPresencePlatform _platform;
  final Duration minimumPageInterval;
  Timer? _timer;
  _ReadingPresence? _lastSubmitted;
  _ReadingPresence? _pending;
  DateTime? _submittedAt;
  Future<void>? _activeSubmission;
  int _generation = 0;
  bool _disposed = false;

  Future<void> update({
    required bool enabled,
    required bool connected,
    required bool shareTitle,
    required String title,
    required String chapterLabel,
    required int pageIndex,
    required int pageCount,
  }) async {
    if (_disposed) return;
    if (!enabled || !connected) {
      await stop();
      return;
    }
    // Privacy mode applies to the complete publication identity, not just the
    // title field. Some catalogs repeat the series name in the chapter label,
    // so forwarding that label would silently undo the user's opt-out.
    final next = _ReadingPresence(
      title: shareTitle
          ? _boundedDiscordText(title, maximumCodeUnits: 120)
          : 'Reading manga',
      chapterLabel: shareTitle
          ? _boundedDiscordText(chapterLabel, maximumCodeUnits: 80)
          : 'Private chapter',
      page: pageCount <= 0 ? 0 : (pageIndex + 1).clamp(1, pageCount),
      pageCount: pageCount.clamp(0, 1000),
    );
    if (next == _lastSubmitted || next == _pending) return;
    if (_activeSubmission != null) {
      _pending = next;
      return;
    }

    final identityChanged =
        _lastSubmitted == null ||
        _lastSubmitted!.title != next.title ||
        _lastSubmitted!.chapterLabel != next.chapterLabel;
    final elapsed = _submittedAt == null
        ? minimumPageInterval
        : DateTime.now().difference(_submittedAt!);
    if (identityChanged || elapsed >= minimumPageInterval) {
      await _submit(next);
      return;
    }

    _pending = next;
    _timer ??= Timer(minimumPageInterval - elapsed, () {
      _timer = null;
      final value = _pending;
      _pending = null;
      if (value != null) unawaited(_submit(value));
    });
  }

  Future<void> _submit(_ReadingPresence value) async {
    final generation = ++_generation;
    _pending = null;
    _timer?.cancel();
    _timer = null;
    final submission = _platform.updateReading(
      title: value.title,
      chapterLabel: value.chapterLabel,
      page: value.page,
      pageCount: value.pageCount,
    );
    _activeSubmission = submission;
    try {
      await submission;
    } finally {
      if (identical(_activeSubmission, submission)) {
        _activeSubmission = null;
      }
    }
    if (_disposed || generation != _generation) return;
    _lastSubmitted = value;
    _submittedAt = DateTime.now();

    final queued = _pending;
    _pending = null;
    if (queued == null || queued == value) return;
    final identityChanged =
        queued.title != value.title ||
        queued.chapterLabel != value.chapterLabel;
    if (identityChanged || minimumPageInterval == Duration.zero) {
      await _submit(queued);
      return;
    }
    _pending = queued;
    _timer = Timer(minimumPageInterval, () {
      _timer = null;
      final pending = _pending;
      _pending = null;
      if (pending != null) unawaited(_submit(pending));
    });
  }

  Future<void> stop() async {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    final activeSubmission = _activeSubmission;
    final ownedPresence = _lastSubmitted != null || activeSubmission != null;
    _lastSubmitted = null;
    _submittedAt = null;
    ++_generation;
    if (activeSubmission != null) {
      try {
        await activeSubmission;
      } catch (_) {
        // A failed update still receives a best-effort clear below.
      }
    }
    if (ownedPresence) await _platform.clear();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    ++_generation;
  }
}

String _boundedDiscordText(String value, {required int maximumCodeUnits}) {
  final normalized = value.trim();
  if (normalized.length <= maximumCodeUnits) return normalized;
  var end = maximumCodeUnits;
  final last = normalized.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
  return normalized.substring(0, end).trimRight();
}

class _ReadingPresence {
  const _ReadingPresence({
    required this.title,
    required this.chapterLabel,
    required this.page,
    required this.pageCount,
  });

  final String title;
  final String chapterLabel;
  final int page;
  final int pageCount;

  @override
  bool operator ==(Object other) =>
      other is _ReadingPresence &&
      other.title == title &&
      other.chapterLabel == chapterLabel &&
      other.page == page &&
      other.pageCount == pageCount;

  @override
  int get hashCode => Object.hash(title, chapterLabel, page, pageCount);
}
