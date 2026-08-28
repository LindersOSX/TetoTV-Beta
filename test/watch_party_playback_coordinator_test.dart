import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_playback_coordinator.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const episode = EpisodeReference(
    anilistMediaId: 154587,
    title: 'Frieren',
    episode: 2,
    titleEnglish: 'Frieren: Beyond Journey’s End',
  );
  const release = ReleaseCandidate(
    infoHash: '0123456789abcdef0123456789abcdef01234567',
    magnetUri:
        'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=secret',
    releaseName: '[Group] Frieren - 02 [1080p]',
    seeders: 20,
    sourceId: 'nyaa',
    preferredFileIndex: 2,
    quality: '1080p',
  );

  test('engine generations reject stale progress and route commands', () async {
    final coordinator = WatchPartyPlaybackCoordinator(
      episode: episode,
      release: release,
    );
    addTearDown(coordinator.dispose);
    var mpvPlays = 0;
    var replacementPlays = 0;
    final mpv = coordinator.bindEngine(
      engine: 'mpv',
      play: () async => mpvPlays++,
      pause: () async {},
      seekTo: (_) async {},
    );
    final replacement = coordinator.bindEngine(
      engine: 'mpv-replacement',
      play: () async => replacementPlays++,
      pause: () async {},
      seekTo: (_) async {},
    );
    final samples = <Duration>[];
    final subscription = coordinator.snapshots.listen(
      (sample) => samples.add(sample.position),
    );
    addTearDown(subscription.cancel);

    coordinator.publish(
      mpv,
      position: const Duration(seconds: 5),
      duration: const Duration(minutes: 24),
      playing: true,
      ready: true,
    );
    coordinator.publish(
      replacement,
      position: const Duration(seconds: 6),
      duration: const Duration(minutes: 24),
      playing: true,
      ready: true,
    );
    await coordinator.play();

    expect(replacement.generation, greaterThan(mpv.generation));
    expect(samples, [const Duration(seconds: 6)]);
    expect(mpvPlays, 0);
    expect(replacementPlays, 1);
  });

  test('party media exposes only a digest, never playback capabilities', () {
    final coordinator = WatchPartyPlaybackCoordinator(
      episode: episode,
      release: release,
    );
    addTearDown(coordinator.dispose);

    final serialized = coordinator.media.toJson().toString();

    expect(coordinator.media.timelineFingerprint, hasLength(64));
    expect(coordinator.media.sourceDescriptor?.fingerprint, hasLength(64));
    expect(
      coordinator.media.sourceDescriptor?.sourceClass,
      WatchPartySourceClass.torrent,
    );
    expect(serialized, isNot(contains('magnet:?')));
    expect(serialized, isNot(contains(release.infoHash)));
    expect(serialized, isNot(contains('secret')));
    expect(serialized, isNot(contains('headers')));
    expect(serialized, isNot(contains('stream_url')));
  });

  test('multi-audio party descriptor carries the host requested track', () {
    const multi = ReleaseCandidate(
      infoHash: '0123456789abcdef0123456789abcdef01234567',
      magnetUri: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
      releaseName: '[Group] Frieren - 02 Multi Audio',
      seeders: 20,
      sourceId: 'nyaa',
      audioIntent: ReleaseAudioIntent.multi,
    );
    final coordinator = WatchPartyPlaybackCoordinator(
      episode: episode,
      release: multi,
      requestedAudio: PlaybackAudioPreference.sub,
    );
    addTearDown(coordinator.dispose);

    expect(
      coordinator.media.sourceDescriptor?.audio,
      WatchPartySourceAudio.sub,
    );
    coordinator.updateRequestedAudio(PlaybackAudioPreference.dub);
    expect(
      coordinator.media.sourceDescriptor?.audio,
      WatchPartySourceAudio.dub,
    );
  });

  test('source fingerprint matches the same torrent without revealing it', () {
    const sameTorrentDifferentProvider = ReleaseCandidate(
      infoHash: '0123456789ABCDEF0123456789ABCDEF01234567',
      magnetUri: 'magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567',
      releaseName: 'A differently labeled result',
      seeders: 1,
      sourceId: 'another-repository',
      preferredFileIndex: 2,
      quality: '720p',
      provider: 'Another provider',
    );
    const differentFile = ReleaseCandidate(
      infoHash: '0123456789ABCDEF0123456789ABCDEF01234567',
      magnetUri: 'magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567',
      releaseName: 'A differently labeled result',
      seeders: 1,
      sourceId: 'another-repository',
      preferredFileIndex: 3,
    );
    final descriptor = WatchPartySourceDescriptor.forRelease(release);

    expect(descriptor.matches(sameTorrentDifferentProvider), isTrue);
    expect(descriptor.matches(differentFile), isFalse);
    expect(descriptor.toJson().toString(), isNot(contains(release.infoHash)));
    expect(descriptor.toJson().toString(), isNot(contains('magnet:?')));
  });

  test('web fingerprint matches the same logical provider stream', () {
    final hostUri = Uri.parse(
      'https://cdn.example/anime/frieren/episode-2/master.m3u8?token=signed-url-one',
    );
    final guestUri = Uri.parse(
      'https://cdn.example/anime/frieren/episode-2/master.m3u8?token=different-signed-url',
    );
    final differentUri = Uri.parse(
      'https://cdn.example/anime/frieren/episode-2/backup.m3u8?token=third',
    );
    final hostStream = ReleaseCandidate(
      infoHash: watchPartyWebReleaseIdentity(
        providerId: 'provider-id',
        uri: hostUri,
      ),
      magnetUri: '',
      releaseName: 'Provider / Episode 2 Dub',
      seeders: 0,
      sourceId: 'web:provider-id',
      quality: '1080p',
      provider: 'Provider',
      isDubbed: true,
    );
    final guestStream = ReleaseCandidate(
      infoHash: watchPartyWebReleaseIdentity(
        providerId: 'provider-id',
        uri: guestUri,
      ),
      magnetUri: '',
      releaseName: '  Provider / Episode 2 Dub  ',
      seeders: 0,
      sourceId: 'WEB:PROVIDER-ID',
      quality: '1080P',
      provider: 'provider',
      isDubbed: true,
    );
    final differentStream = ReleaseCandidate(
      infoHash: watchPartyWebReleaseIdentity(
        providerId: 'provider-id',
        uri: differentUri,
      ),
      magnetUri: '',
      releaseName: 'Provider / Episode 2 Dub',
      seeders: 0,
      sourceId: 'web:provider-id',
      quality: '1080p',
      provider: 'Provider',
      isDubbed: true,
    );
    final descriptor = WatchPartySourceDescriptor.forRelease(hostStream);

    expect(descriptor.sourceClass, WatchPartySourceClass.web);
    expect(descriptor.matches(guestStream), isTrue);
    expect(descriptor.matches(differentStream), isFalse);
    expect(descriptor.toJson().toString(), isNot(contains('signed-url')));
    expect(descriptor.toJson().toString(), isNot(contains('cdn.example')));
  });

  test('blank or capability-like Web identities fail closed', () {
    const blank = ReleaseCandidate(
      infoHash: '',
      magnetUri: '',
      releaseName: '',
      seeders: 0,
      sourceId: '',
    );
    const metadataWithoutVariant = ReleaseCandidate(
      infoHash: 'web:provider:local-only',
      magnetUri: '',
      releaseName: 'Provider / Episode 2',
      seeders: 0,
      sourceId: 'web:provider',
      provider: 'Provider',
      quality: '1080p',
    );
    final privatePath = Uri.parse(
      'https://cdn.example/video/0123456789abcdef0123456789abcdef/master.m3u8?token=secret',
    );

    expect(WatchPartySourceDescriptor.tryForRelease(blank), isNull);
    expect(
      WatchPartySourceDescriptor.tryForRelease(metadataWithoutVariant),
      isNull,
    );
    expect(tryWatchPartyWebVariantIdentity(privatePath), isNull);
  });

  test('hex and base32 BTIH representations have one fingerprint', () {
    const hexadecimal = ReleaseCandidate(
      infoHash: '0123456789abcdef0123456789abcdef01234567',
      magnetUri: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
      releaseName: 'Hex',
      seeders: 1,
      sourceId: 'one',
    );
    const base32 = ReleaseCandidate(
      infoHash: 'AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH',
      magnetUri: 'magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH',
      releaseName: 'Base32',
      seeders: 1,
      sourceId: 'two',
    );

    expect(
      tryWatchPartySourceFingerprint(base32),
      tryWatchPartySourceFingerprint(hexadecimal),
    );
  });

  test('blank torrent hash is extracted safely or the descriptor is omitted', () {
    const extractable = ReleaseCandidate(
      infoHash: '',
      magnetUri:
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=https%3A%2F%2Ftracker.invalid%2Fsecret',
      releaseName: 'Extractable',
      seeders: 1,
      sourceId: 'manual',
    );
    const unidentifiable = ReleaseCandidate(
      infoHash: '',
      magnetUri: 'magnet:?dn=NoIdentity',
      releaseName: 'Unidentifiable',
      seeders: 1,
      sourceId: 'manual',
    );
    final extracted = WatchPartySourceDescriptor.tryForRelease(extractable);
    final omitted = WatchPartySourceDescriptor.tryForRelease(unidentifiable);

    expect(extracted?.fingerprint, hasLength(64));
    expect(extracted?.toJson().toString(), isNot(contains('tracker.invalid')));
    expect(extracted?.toJson().toString(), isNot(contains('0123456789abcdef')));
    expect(omitted, isNull);

    final coordinator = WatchPartyPlaybackCoordinator(
      episode: episode,
      release: unidentifiable,
    );
    addTearDown(coordinator.dispose);
    expect(coordinator.media.sourceDescriptor, isNull);
  });

  test('untrusted source descriptors fail closed without throwing', () {
    final base = <String, Object?>{
      'version': 1,
      'class': 'web',
      'fingerprint': List<String>.filled(64, 'a').join(),
      'audio': 'dub',
    };

    expect(
      WatchPartySourceDescriptor.tryFromJson(<String, Object?>{
        ...base,
        'quality_height': '1080',
      }),
      isNull,
    );
    expect(
      WatchPartySourceDescriptor.tryFromJson(<String, Object?>{
        ...base,
        'url': 'https://private.invalid/video',
      }),
      isNull,
    );
  });

  test('known duration contributes to the hashed timeline identity', () async {
    final coordinator = WatchPartyPlaybackCoordinator(
      episode: episode,
      release: release,
    );
    addTearDown(coordinator.dispose);
    final handle = coordinator.bindEngine(
      engine: 'mpv',
      play: () async {},
      pause: () async {},
      seekTo: (_) async {},
    );
    final sampleFuture = coordinator.snapshots.first;

    coordinator.publish(
      handle,
      position: Duration.zero,
      duration: const Duration(minutes: 24),
      playing: false,
      ready: true,
    );
    final sample = await sampleFuture;

    expect(
      sample.media.timelineFingerprint,
      isNot(coordinator.media.timelineFingerprint),
    );
  });

  test(
    'changing sources clears the previous release timeline anchors',
    () async {
      final coordinator = WatchPartyPlaybackCoordinator(
        episode: episode,
        release: release,
      );
      addTearDown(coordinator.dispose);
      final handle = coordinator.bindEngine(
        engine: 'mpv',
        play: () async {},
        pause: () async {},
        seekTo: (_) async {},
      );
      coordinator.updateTimelineAnchors(const [
        WatchPartyTimelineAnchor(
          kind: WatchPartyTimelineAnchorKind.openingStart,
          position: Duration(seconds: 30),
        ),
        WatchPartyTimelineAnchor(
          kind: WatchPartyTimelineAnchorKind.openingEnd,
          position: Duration(minutes: 2),
        ),
      ]);
      final samples = <WatchPartyPlaybackSample>[];
      final subscription = coordinator.snapshots.listen(samples.add);
      addTearDown(subscription.cancel);

      coordinator.publish(
        handle,
        position: Duration.zero,
        duration: const Duration(minutes: 24),
        playing: false,
        ready: true,
      );
      coordinator.updateMedia(
        episode: episode,
        release: const ReleaseCandidate(
          infoHash: 'abcdef0123456789abcdef0123456789abcdef01',
          magnetUri:
              'magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01',
          releaseName: '[Other] Frieren - 02 [1080p]',
          seeders: 10,
          sourceId: 'nyaa',
        ),
      );
      coordinator.publish(
        handle,
        position: Duration.zero,
        duration: const Duration(minutes: 24),
        playing: false,
        ready: true,
      );

      expect(samples.first.media.timelineProfile?.anchors, hasLength(2));
      expect(samples.last.media.timelineProfile?.anchors, isEmpty);
    },
  );

  test('private media publishes only a one-way timeline digest', () {
    const privateIdentity = 'server-token:item-42:https://private.example';
    final coordinator = WatchPartyPlaybackCoordinator.privateMedia(
      checkpointKey: 'local:0123456789abcdef',
      timelineIdentity: privateIdentity,
    );
    addTearDown(coordinator.dispose);

    final serialized = coordinator.media.toJson().toString();

    expect(coordinator.media.kind, 'private');
    expect(coordinator.media.title, 'Private media');
    expect(coordinator.media.timelineFingerprint, hasLength(64));
    expect(serialized, isNot(contains(privateIdentity)));
    expect(serialized, isNot(contains('server-token')));
    expect(serialized, isNot(contains('https://')));
    expect(serialized, isNot(contains('headers')));
  });

  test('public library episode exposes only public catalog identity', () {
    final coordinator = WatchPartyPlaybackCoordinator.publicCatalogEpisode(
      anilistMediaId: 154587,
      episode: 2,
      title: '  Frieren\nEpisode 2  ',
    );
    addTearDown(coordinator.dispose);
    coordinator.updateMedia(
      episode: const EpisodeReference(
        anilistMediaId: 0,
        title: 'Private library placeholder',
        episode: 1,
      ),
      release: const ReleaseCandidate(
        infoHash: '',
        magnetUri: '',
        releaseName: 'Local server item',
        seeders: 0,
        sourceId: 'local',
      ),
    );

    final media = coordinator.media;
    final serialized = media.toJson().toString();

    expect(media.kind, 'anilist');
    expect(media.anilistId, 154587);
    expect(media.episode, 2);
    expect(media.title, 'Frieren Episode 2');
    expect(media.timelineFingerprint, isNull);
    expect(serialized, isNot(contains('checkpoint')));
    expect(serialized, isNot(contains('timeline')));
    expect(serialized, isNot(contains('source')));
    expect(serialized, isNot(contains('headers')));
  });

  test('room titles are normalized to the broker media limit', () {
    final longTitle = '  ${'Very long title '.padRight(220, 'x')}\n  ';
    final publicCoordinator =
        WatchPartyPlaybackCoordinator.publicCatalogEpisode(
          anilistMediaId: 154587,
          episode: 2,
          title: longTitle,
        );
    final privateCoordinator = WatchPartyPlaybackCoordinator.privateMedia(
      checkpointKey: 'local:bounded-title',
      timelineIdentity: 'private-bounded-title',
      displayTitle: longTitle,
    );
    final emojiCoordinator = WatchPartyPlaybackCoordinator.publicCatalogEpisode(
      anilistMediaId: 154587,
      episode: 2,
      title: List.filled(100, '🙂').join(),
    );
    addTearDown(publicCoordinator.dispose);
    addTearDown(privateCoordinator.dispose);
    addTearDown(emojiCoordinator.dispose);

    expect(publicCoordinator.media.title.runes.length, 160);
    expect(privateCoordinator.media.title.runes.length, 160);
    expect(emojiCoordinator.media.title.length, 160);
    expect(emojiCoordinator.media.title.runes.length, 80);
    expect(publicCoordinator.media.title, isNot(contains('\n')));
    expect(privateCoordinator.media.title, isNot(contains('\n')));
  });
}
