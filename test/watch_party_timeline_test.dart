import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WatchPartyTimelineProfile profile({
    required int durationSeconds,
    int? openingStart,
    int? openingEnd,
    int? endingStart,
    int? endingEnd,
  }) => WatchPartyTimelineProfile.tryCreate(
    duration: Duration(seconds: durationSeconds),
    anchors: <WatchPartyTimelineAnchor>[
      if (openingStart != null)
        WatchPartyTimelineAnchor(
          kind: WatchPartyTimelineAnchorKind.openingStart,
          position: Duration(seconds: openingStart),
        ),
      if (openingEnd != null)
        WatchPartyTimelineAnchor(
          kind: WatchPartyTimelineAnchorKind.openingEnd,
          position: Duration(seconds: openingEnd),
        ),
      if (endingStart != null)
        WatchPartyTimelineAnchor(
          kind: WatchPartyTimelineAnchorKind.endingStart,
          position: Duration(seconds: endingStart),
        ),
      if (endingEnd != null)
        WatchPartyTimelineAnchor(
          kind: WatchPartyTimelineAnchorKind.endingEnd,
          position: Duration(seconds: endingEnd),
        ),
    ],
  )!;

  test('timeline profile is bounded and contains timing only', () {
    final value = profile(
      durationSeconds: 1440,
      openingStart: 60,
      openingEnd: 150,
      endingStart: 1320,
      endingEnd: 1410,
    );
    final json = value.toJson();
    final serialized = json.toString();

    expect(WatchPartyTimelineProfile.tryFromJson(json), value);
    expect(serialized, isNot(contains('url')));
    expect(serialized, isNot(contains('token')));
    expect(serialized, isNot(contains('filename')));
    expect(serialized, isNot(contains('provider')));
  });

  test('same release keeps its raw position with a local adjustment', () {
    final value = profile(durationSeconds: 1440);
    final mapped = mapWatchPartyTimeline(
      hostPosition: const Duration(minutes: 10),
      host: value,
      guest: value,
      exactFingerprint: true,
      guestOffset: const Duration(seconds: -3),
    );

    expect(mapped.position, const Duration(minutes: 9, seconds: 57));
    expect(mapped.compatibility, WatchPartyTimelineCompatibility.exact);
    expect(mapped.usedTimelineMapping, isFalse);
  });

  test('alternate release with the same duration is compatible', () {
    final host = profile(durationSeconds: 1440);
    final guest = profile(durationSeconds: 1441);
    final mapped = mapWatchPartyTimeline(
      hostPosition: const Duration(minutes: 10),
      host: host,
      guest: guest,
      exactFingerprint: false,
    );

    expect(mapped.position, const Duration(minutes: 10));
    expect(mapped.compatibility, WatchPartyTimelineCompatibility.compatible);
  });

  test('two shared boundaries align a shifted alternate cut', () {
    final host = profile(
      durationSeconds: 1440,
      openingStart: 60,
      openingEnd: 150,
      endingStart: 1320,
      endingEnd: 1410,
    );
    final guest = profile(
      durationSeconds: 1470,
      openingStart: 90,
      openingEnd: 180,
      endingStart: 1350,
      endingEnd: 1440,
    );
    final mapped = mapWatchPartyTimeline(
      hostPosition: const Duration(minutes: 10),
      host: host,
      guest: guest,
      exactFingerprint: false,
    );

    expect(mapped.position, const Duration(minutes: 10, seconds: 30));
    expect(mapped.compatibility, WatchPartyTimelineCompatibility.adjusted);
    expect(mapped.usedTimelineMapping, isTrue);
  });

  test('duration difference alone never guesses a scene offset', () {
    final host = profile(durationSeconds: 1440);
    final guest = profile(durationSeconds: 1470);
    final mapped = mapWatchPartyTimeline(
      hostPosition: const Duration(minutes: 10),
      host: host,
      guest: guest,
      exactFingerprint: false,
    );

    expect(mapped.position, const Duration(minutes: 10));
    expect(mapped.compatibility, WatchPartyTimelineCompatibility.differentCut);
    expect(mapped.usedTimelineMapping, isFalse);
  });

  test('media round trip retains the public timeline profile', () {
    final timeline = profile(
      durationSeconds: 1440,
      openingStart: 60,
      openingEnd: 150,
    );
    final media = WatchPartyMedia(
      kind: 'anilist',
      title: 'Frieren',
      anilistId: 154587,
      episode: 2,
      timelineProfile: timeline,
    );

    expect(WatchPartyMedia.fromJson(media.toJson()).timelineProfile, timeline);
  });

  test('malformed or capability-shaped profiles fail closed', () {
    expect(
      WatchPartyTimelineProfile.tryFromJson(<String, Object?>{
        'version': 1,
        'duration_ms': 1440000,
        'anchors': <Object>[],
        'url': 'https://private.invalid/video',
      }),
      isNull,
    );
    expect(
      WatchPartyTimelineProfile.tryFromJson(<String, Object?>{
        'version': 1,
        'duration_ms': 1440000,
        'anchors': <Object>[
          <String, Object>{'kind': 'opening_start', 'position_ms': 1500000},
        ],
      }),
      isNull,
    );
    expect(
      WatchPartyTimelineProfile.tryFromJson(<String, Object?>{
        'version': 1,
        'duration_ms': '1440000',
        'anchors': <Object>[],
      }),
      isNull,
    );
    expect(
      WatchPartyTimelineProfile.tryFromJson(<String, Object?>{
        'version': 1,
        'duration_ms': 1440000,
        'anchors': <Object>[
          <String, Object>{'kind': 'opening_start', 'position_ms': '60000'},
        ],
      }),
      isNull,
    );
  });
}
