import 'package:anime_tv/features/streaming/domain/external_audio_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ExternalAudioTrack track(int index) => ExternalAudioTrack(
    uri: Uri.parse('http://127.0.0.1:49152/session/audio-$index'),
  );

  test(
    'optional audio attachment salvages failures and remains bounded',
    () async {
      final attempted = <int>[];
      final result = await attachOptionalExternalAudioTracks(
        tracks: List.generate(12, track),
        isCurrent: () => true,
        attach: (audio) async {
          final index = int.parse(audio.uri.path.split('-').last);
          attempted.add(index);
          if (index == 2) throw StateError('unsupported fixture');
        },
      );

      expect(attempted, List.generate(8, (index) => index));
      expect(result.requestedCount, 8);
      expect(result.attachedCount, 7);
      expect(result.failedCount, 1);
      expect(result.staleCount, 0);
    },
  );

  test(
    'optional audio attachment stops before mutating a newer open',
    () async {
      var current = true;
      final attempted = <Uri>[];
      final result = await attachOptionalExternalAudioTracks(
        tracks: List.generate(3, track),
        isCurrent: () => current,
        attach: (audio) async {
          attempted.add(audio.uri);
          current = false;
        },
      );

      expect(attempted, [track(0).uri]);
      expect(result.attachedCount, 1);
      expect(result.failedCount, 0);
      expect(result.staleCount, 2);
    },
  );
}
