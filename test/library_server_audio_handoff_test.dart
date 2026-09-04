import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  LibraryPlaybackRequest request({
    required bool compatibility,
    required LibraryServerAudioSelectionCallback? onSelected,
    String selectedTrackId = 'jpn',
  }) => LibraryPlaybackRequest(
    source: Uri.parse('https://media.example/stream.m3u8'),
    title: 'Episode',
    releaseName: 'Episode',
    streamLabel: 'Jellyfin',
    checkpointKey: 'local:server-audio-test',
    timelineIdentity: 'server-audio-test',
    serverAudioTracks: [
      LibraryServerAudioTrack(id: 'jpn', label: 'Japanese', language: 'jpn'),
      LibraryServerAudioTrack(id: 'eng', label: 'English', language: 'eng'),
    ],
    selectedServerAudioTrackId: selectedTrackId,
    onServerAudioTrackSelected: onSelected,
    isCompatibilityStream: compatibility,
  );

  test('compatibility stream exposes its server audio picker', () {
    final compatibilityRequest = request(
      compatibility: true,
      onSelected: (_, _) async => throw UnimplementedError(),
    );

    expect(
      shouldUseLibraryServerAudioPicker(
        request: compatibilityRequest,
        embeddedTrackCount: 1,
      ),
      isTrue,
    );
    expect(
      shouldUseLibraryServerAudioPicker(
        request: compatibilityRequest,
        embeddedTrackCount: 2,
      ),
      isFalse,
      reason: 'MPV remains authoritative when it exposes every track',
    );
    expect(
      shouldUseLibraryServerAudioPicker(
        request: request(
          compatibility: false,
          onSelected: (_, _) async => throw UnimplementedError(),
        ),
        embeddedTrackCount: 1,
      ),
      isFalse,
      reason: 'direct play keeps the existing embedded-track picker',
    );
  });

  test(
    'server audio selection reaches the owning player handoff exactly',
    () async {
      String? preparedTrackId;
      Duration? preparedPosition;
      LibraryPlaybackRequest? handedOff;
      late final LibraryPlaybackRequest original;
      original = request(
        compatibility: true,
        onSelected: (trackId, position) async {
          preparedTrackId = trackId;
          preparedPosition = position;
          return request(
            compatibility: true,
            selectedTrackId: trackId,
            onSelected: original.onServerAudioTrackSelected,
          );
        },
      );

      final adopted = await handoffLibraryServerAudioTrack(
        request: original,
        trackId: 'eng',
        position: const Duration(minutes: 8),
        handoff: (replacement) async {
          handedOff = replacement;
          return true;
        },
      );

      expect(adopted, isTrue);
      expect(preparedTrackId, 'eng');
      expect(preparedPosition, const Duration(minutes: 8));
      expect(handedOff?.selectedServerAudioTrackId, 'eng');
    },
  );

  test('server audio handoff clamps a negative player position', () async {
    Duration? preparedPosition;
    late final LibraryPlaybackRequest original;
    original = request(
      compatibility: true,
      onSelected: (trackId, position) async {
        preparedPosition = position;
        return request(
          compatibility: true,
          selectedTrackId: trackId,
          onSelected: original.onServerAudioTrackSelected,
        );
      },
    );

    await handoffLibraryServerAudioTrack(
      request: original,
      trackId: 'eng',
      position: const Duration(seconds: -1),
      handoff: (_) async => true,
    );

    expect(preparedPosition, Duration.zero);
  });
}
