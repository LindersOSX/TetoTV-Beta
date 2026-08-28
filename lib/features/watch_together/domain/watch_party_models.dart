import 'package:flutter/foundation.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';

enum WatchPartyRole { host, guest }

const int maximumWatchPartyDisplayNameLength = 48;
const int maximumWatchPartyAvatarUrlLength = 512;
const int maximumWatchPartyGuestCount = 20;
const int maximumWatchPartyRosterSize = maximumWatchPartyGuestCount + 1;
const int maximumWatchPartyEventCount = 16;

const _watchPartyAvatarHosts = <String>{'s4.anilist.co', 'cdn.myanimelist.net'};

@immutable
class WatchPartyPublicIdentity {
  const WatchPartyPublicIdentity._({required this.displayName, this.avatarUrl});

  final String displayName;
  final String? avatarUrl;

  static WatchPartyPublicIdentity? tryCreate({
    required Object? displayName,
    Object? avatarUrl,
  }) {
    final safeName = _safeWatchPartyDisplayName(displayName);
    if (safeName == null) return null;
    return WatchPartyPublicIdentity._(
      displayName: safeName,
      // An unsafe profile picture is optional and is simply not shared.
      avatarUrl: _safeWatchPartyAvatarUrl(avatarUrl),
    );
  }

  Map<String, Object> toJson() => switch (avatarUrl) {
    final avatar? => <String, Object>{
      'display_name': displayName,
      'avatar_url': avatar,
    },
    null => <String, Object>{'display_name': displayName},
  };
}

@immutable
class WatchPartyParticipant {
  const WatchPartyParticipant({
    required this.displayName,
    required this.role,
    required this.ready,
    this.participantId,
    this.avatarUrl,
  });

  final String displayName;
  final String? participantId;
  final String? avatarUrl;
  final WatchPartyRole role;
  final bool ready;

  static WatchPartyParticipant? tryFromJson(Map<String, Object?> value) {
    const allowedKeys = <String>{
      'display_name',
      'avatar_url',
      'participant_id',
      'role',
      'ready',
    };
    if (value.keys.any((key) => !allowedKeys.contains(key))) return null;
    final displayName = _safeWatchPartyDisplayName(value['display_name']);
    final role = switch (value['role']) {
      'host' => WatchPartyRole.host,
      'guest' => WatchPartyRole.guest,
      _ => null,
    };
    final ready = value['ready'];
    final avatarValue = value['avatar_url'];
    final avatarUrl = _safeWatchPartyAvatarUrl(avatarValue);
    final participantId = _safeWatchPartyParticipantId(value['participant_id']);
    if (displayName == null ||
        role == null ||
        ready is! bool ||
        (value['participant_id'] != null && participantId == null) ||
        (avatarValue != null && avatarUrl == null)) {
      return null;
    }
    return WatchPartyParticipant(
      displayName: displayName,
      participantId: participantId,
      avatarUrl: avatarUrl,
      role: role,
      ready: ready,
    );
  }
}

String? _safeWatchPartyParticipantId(Object? value) {
  if (value == null) return null;
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(value)) {
    return null;
  }
  return value;
}

enum WatchPartyEventType { joined, left, kicked, hostTransferred }

@immutable
class WatchPartyEvent {
  const WatchPartyEvent({
    required this.sequence,
    required this.type,
    required this.displayName,
  });

  final int sequence;
  final WatchPartyEventType type;
  final String displayName;

  static WatchPartyEvent? tryFromJson(Map<String, Object?> value) {
    const allowedKeys = <String>{'sequence', 'type', 'display_name'};
    if (value.keys.any((key) => !allowedKeys.contains(key))) return null;
    final sequence = (value['sequence'] as num?)?.toInt();
    final displayName = _safeWatchPartyDisplayName(value['display_name']);
    final type = switch (value['type']) {
      'joined' => WatchPartyEventType.joined,
      'left' => WatchPartyEventType.left,
      'kicked' => WatchPartyEventType.kicked,
      'host_transferred' => WatchPartyEventType.hostTransferred,
      _ => null,
    };
    if (sequence == null ||
        sequence <= 0 ||
        displayName == null ||
        type == null) {
      return null;
    }
    return WatchPartyEvent(
      sequence: sequence,
      type: type,
      displayName: displayName,
    );
  }
}

String? _safeWatchPartyDisplayName(Object? value) {
  if (value is! String) return null;
  final normalized = value
      .trim()
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty ||
      normalized.length > maximumWatchPartyDisplayNameLength ||
      RegExp(r'\S+@\S+\.\S+').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _safeWatchPartyAvatarUrl(Object? value) {
  if (value == null) return null;
  if (value is! String || value.length > maximumWatchPartyAvatarUrlLength) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 443) ||
      uri.path.contains('\\') ||
      !_watchPartyAvatarHosts.contains(uri.host.toLowerCase())) {
    return null;
  }
  return uri.toString();
}

@immutable
class WatchPartyMedia {
  const WatchPartyMedia({
    required this.kind,
    required this.title,
    this.anilistId,
    this.episode,
    this.titleEnglish,
    this.titleRomaji,
    this.year,
    this.coverUrl,
    this.timelineFingerprint,
    this.timelineProfile,
    this.sourceDescriptor,
  });

  final String kind;
  final String title;
  final int? anilistId;
  final int? episode;
  final String? titleEnglish;
  final String? titleRomaji;
  final int? year;
  final String? coverUrl;
  final String? timelineFingerprint;
  final WatchPartyTimelineProfile? timelineProfile;
  final WatchPartySourceDescriptor? sourceDescriptor;

  bool get isCatalogEpisode =>
      kind == 'anilist' && anilistId != null && episode != null;

  Map<String, Object> toJson() {
    final value = <String, Object>{'kind': kind, 'title': title};
    void add(String key, Object? item) {
      if (item != null) value[key] = item;
    }

    add('anilist_id', anilistId);
    add('episode', episode);
    add('title_english', titleEnglish);
    add('title_romaji', titleRomaji);
    add('year', year);
    add('cover_url', coverUrl);
    add('timeline_fingerprint', timelineFingerprint);
    add('timeline_profile', timelineProfile?.toJson());
    add('source_descriptor', sourceDescriptor?.toJson());
    return value;
  }

  factory WatchPartyMedia.fromJson(Map<String, Object?> value) {
    final sourceDescriptorValue = value['source_descriptor'];
    final timelineProfileValue = value['timeline_profile'];
    return WatchPartyMedia(
      kind: value['kind'] as String? ?? 'private',
      title: value['title'] as String? ?? 'Watch Party',
      anilistId: (value['anilist_id'] as num?)?.toInt(),
      episode: (value['episode'] as num?)?.toInt(),
      titleEnglish: value['title_english'] as String?,
      titleRomaji: value['title_romaji'] as String?,
      year: (value['year'] as num?)?.toInt(),
      coverUrl: value['cover_url'] as String?,
      timelineFingerprint: value['timeline_fingerprint'] as String?,
      timelineProfile: timelineProfileValue is Map
          ? WatchPartyTimelineProfile.tryFromJson(
              timelineProfileValue.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            )
          : null,
      sourceDescriptor: sourceDescriptorValue is Map
          ? WatchPartySourceDescriptor.tryFromJson(
              sourceDescriptorValue.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            )
          : null,
    );
  }

  WatchPartyMedia withoutSourceDescriptor() => WatchPartyMedia(
    kind: kind,
    title: title,
    anilistId: anilistId,
    episode: episode,
    titleEnglish: titleEnglish,
    titleRomaji: titleRomaji,
    year: year,
    coverUrl: coverUrl,
    timelineFingerprint: timelineFingerprint,
    timelineProfile: timelineProfile,
  );

  WatchPartyMedia withoutTimelineProfile() => WatchPartyMedia(
    kind: kind,
    title: title,
    anilistId: anilistId,
    episode: episode,
    titleEnglish: titleEnglish,
    titleRomaji: titleRomaji,
    year: year,
    coverUrl: coverUrl,
    timelineFingerprint: timelineFingerprint,
    sourceDescriptor: sourceDescriptor,
  );

  bool sameTimeline(WatchPartyMedia other) =>
      kind == other.kind &&
      anilistId == other.anilistId &&
      episode == other.episode &&
      (timelineFingerprint == null ||
          other.timelineFingerprint == null ||
          timelineFingerprint == other.timelineFingerprint);

  @override
  bool operator ==(Object other) =>
      other is WatchPartyMedia &&
      kind == other.kind &&
      title == other.title &&
      anilistId == other.anilistId &&
      episode == other.episode &&
      titleEnglish == other.titleEnglish &&
      titleRomaji == other.titleRomaji &&
      year == other.year &&
      coverUrl == other.coverUrl &&
      timelineFingerprint == other.timelineFingerprint &&
      timelineProfile == other.timelineProfile &&
      sourceDescriptor == other.sourceDescriptor;

  @override
  int get hashCode => Object.hash(
    kind,
    title,
    anilistId,
    episode,
    titleEnglish,
    titleRomaji,
    year,
    coverUrl,
    timelineFingerprint,
    timelineProfile,
    sourceDescriptor,
  );
}

@immutable
class WatchPartySnapshot {
  const WatchPartySnapshot({
    required this.roomCode,
    required this.role,
    required this.revision,
    this.resyncRevision = 0,
    required this.playing,
    required this.position,
    required this.effectiveAt,
    required this.serverTime,
    this.receivedAt,
    required this.participantCount,
    required this.readyCount,
    this.rosterRevision = 0,
    required this.expiresAt,
    this.participants = const <WatchPartyParticipant>[],
    this.events = const <WatchPartyEvent>[],
    this.media,
  });

  final String roomCode;
  final WatchPartyRole role;
  final int revision;
  final int resyncRevision;
  final WatchPartyMedia? media;
  final bool playing;
  final Duration position;
  final DateTime effectiveAt;
  final DateTime serverTime;

  /// Local clock anchor captured when this snapshot was received.
  ///
  /// The server offset must remain fixed after receipt. Recomputing it from
  /// every later [localNow] pins server time to this snapshot and repeatedly
  /// seeks a playing guest backward.
  final DateTime? receivedAt;
  final int participantCount;
  final int readyCount;
  final int rosterRevision;
  final List<WatchPartyParticipant> participants;
  final List<WatchPartyEvent> events;
  final DateTime expiresAt;

  Duration expectedPositionAt(DateTime localNow) {
    final clockOffset = serverTime.difference(receivedAt ?? serverTime);
    final serverNow = localNow.add(clockOffset);
    final elapsed = playing ? serverNow.difference(effectiveAt) : Duration.zero;
    final value = position + elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  factory WatchPartySnapshot.fromJson(
    Map<String, Object?> value, {
    DateTime? receivedAt,
  }) {
    final media = value['media'];
    final participantCount =
        ((value['participant_count'] as num?)?.toInt() ?? 0).clamp(
          0,
          maximumWatchPartyGuestCount,
        );
    final readyCount = ((value['ready_count'] as num?)?.toInt() ?? 0).clamp(
      0,
      participantCount,
    );
    final participants = <WatchPartyParticipant>[];
    if (value['participants'] case final List<Object?> roster) {
      for (final item in roster.take(maximumWatchPartyRosterSize)) {
        if (item is! Map) continue;
        final participant = WatchPartyParticipant.tryFromJson(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (participant != null) participants.add(participant);
      }
    }
    final events = <WatchPartyEvent>[];
    if (value['events'] case final List<Object?> rawEvents) {
      for (final item in rawEvents.take(maximumWatchPartyEventCount)) {
        if (item is! Map) continue;
        final event = WatchPartyEvent.tryFromJson(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (event != null) events.add(event);
      }
      events.sort((left, right) => left.sequence.compareTo(right.sequence));
    }
    return WatchPartySnapshot(
      roomCode: value['room_code'] as String? ?? '',
      role: value['role'] == 'host'
          ? WatchPartyRole.host
          : WatchPartyRole.guest,
      revision: (value['revision'] as num?)?.toInt() ?? 0,
      resyncRevision: ((value['resync_revision'] as num?)?.toInt() ?? 0).clamp(
        0,
        1 << 53,
      ),
      media: media is Map
          ? WatchPartyMedia.fromJson(
              media.map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
      playing: value['playing'] as bool? ?? false,
      position: Duration(
        milliseconds: (value['position_ms'] as num?)?.toInt() ?? 0,
      ),
      effectiveAt: DateTime.fromMillisecondsSinceEpoch(
        (value['effective_at_ms'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      serverTime: DateTime.fromMillisecondsSinceEpoch(
        (value['server_time_ms'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      receivedAt: (receivedAt ?? DateTime.now()).toUtc(),
      participantCount: participantCount,
      readyCount: readyCount,
      rosterRevision: ((value['roster_revision'] as num?)?.toInt() ?? 0).clamp(
        0,
        1 << 53,
      ),
      participants: List<WatchPartyParticipant>.unmodifiable(participants),
      events: List<WatchPartyEvent>.unmodifiable(events),
      expiresAt:
          DateTime.tryParse(value['expires_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

@immutable
class WatchPartySession {
  const WatchPartySession({
    required this.roomCode,
    required this.token,
    required this.role,
    required this.expiresAt,
    required this.watchUrl,
  });

  final String roomCode;
  final String token;
  final WatchPartyRole role;
  final DateTime expiresAt;
  final Uri watchUrl;

  WatchPartySession withRole(WatchPartyRole nextRole) => WatchPartySession(
    roomCode: roomCode,
    token: token,
    role: nextRole,
    expiresAt: expiresAt,
    watchUrl: watchUrl,
  );
}

@immutable
class WatchPartyPlaybackSample {
  const WatchPartyPlaybackSample({
    required this.media,
    required this.position,
    required this.duration,
    required this.playing,
    required this.ready,
    required this.sampledAt,
  });

  final WatchPartyMedia media;
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool ready;
  final DateTime sampledAt;
}

abstract interface class WatchPartyPlaybackPort {
  Stream<WatchPartyPlaybackSample> get snapshots;

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);
}
