import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/catalogs/playback_strings.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/player/application/audio_track_selector.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:anime_tv/features/player/presentation/teto_player_chrome.dart';
import 'package:anime_tv/features/player/presentation/watch_party_player_status.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  for (final (code, tag) in const [
    ('es', 'es-MX'),
    ('pt', 'pt-BR'),
    ('fr', 'fr-FR'),
    ('hi', 'hi-IN'),
    ('de', 'de-DE'),
  ]) {
    test('$code UI defaults match available audio and full captions', () {
      final language = AppLanguage.fromCode(code).mediaLanguage;
      final effective = preferredPlaybackAudioLanguage(
        globalPreference: PlaybackAudioPreference.dub,
        globalLanguage: language,
      );
      final tracks = [
        const AudioTrack(
          'original',
          'Original Japanese',
          'jpn',
          isDefault: true,
        ),
        AudioTrack('wanted', 'Localized dialogue', tag),
        AudioTrack('commentary', 'Commentary', tag),
      ];
      expect(
        preferredAudioTrackForLanguage(tracks, language: effective)?.id,
        'wanted',
      );
      final captionScores = <String, int>{
        'english': playerTrackLanguageScore(
          language: 'eng',
          title: 'English',
          preferredLanguage: language,
          subtitle: true,
        ),
        'wanted': playerTrackLanguageScore(
          language: tag,
          title: 'Full dialogue',
          preferredLanguage: language,
          subtitle: true,
        ),
        'signs': playerTrackLanguageScore(
          language: tag,
          title: 'Signs and songs',
          preferredLanguage: language,
          subtitle: true,
        ),
      };
      expect(captionScores['wanted'], greaterThan(0));
      expect(captionScores['wanted'], greaterThan(captionScores['signs']!));
      expect(captionScores['english'], 0);
      final explicitSeries = preferredPlaybackAudioLanguage(
        globalPreference: PlaybackAudioPreference.dub,
        globalLanguage: language,
        seriesLanguage: 'jpn',
        seriesPreferenceSet: true,
      );
      expect(
        preferredAudioTrackForLanguage(tracks, language: explicitSeries)?.id,
        'original',
      );
    });
  }
  test(
    'every playback message has five translations with intact placeholders',
    () {
      final placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}');
      Set<String> names(String value) =>
          placeholder.allMatches(value).map((match) => match[1]!).toSet();
      for (final entry in playbackTranslationRows.entries) {
        expect(entry.value, hasLength(5), reason: entry.key);
        for (final translation in entry.value) {
          expect(translation.trim(), isNotEmpty, reason: entry.key);
          expect(
            names(translation),
            names(entry.key),
            reason: '${entry.key} -> $translation',
          );
        }
      }
      expect(
        playbackTranslations.keys,
        unorderedEquals(['es', 'pt', 'fr', 'hi', 'de']),
      );
    },
  );

  test('values are inserted unchanged rather than translated as UI text', () {
    final translations = TetoLocalizations(AppLanguage.fromCode('es'));
    expect(
      translations.text('Playing {value1}', {'value1': 'Close {value1} 日本語'}),
      'Reproduciendo Close {value1} 日本語',
    );
    expect(
      translations.text('An external title not in the catalog'),
      'An external title not in the catalog',
    );
    expect(translations.text('Track {value1}', {'value1': 3}), 'Pista 3');
  });

  for (final language in ['es', 'pt', 'fr', 'hi', 'de']) {
    test('$language Watch Party HUD badges preserve room codes and state', () {
      final locale = TetoLocalizations(AppLanguage.fromCode(language));
      final session = WatchPartySession(
        roomCode: '23456789',
        token: 'test-token-not-rendered',
        role: WatchPartyRole.guest,
        expiresAt: DateTime.utc(2027),
        watchUrl: Uri.parse('https://example.com/watch'),
      );
      for (final (compatibility, label) in [
        (WatchPartyTimelineCompatibility.exact, 'EXACT SOURCE'),
        (WatchPartyTimelineCompatibility.compatible, 'SOURCE ALIGNED'),
        (WatchPartyTimelineCompatibility.adjusted, 'TIMELINE ADJUSTED'),
        (WatchPartyTimelineCompatibility.differentCut, 'DIFFERENT CUT'),
        (WatchPartyTimelineCompatibility.unverified, 'VERIFYING'),
      ]) {
        final state = WatchPartyState(
          session: session,
          connection: WatchPartyConnection.connected,
          timelineCompatibility: compatibility,
        );
        // Default English remains stable for controller change detection.
        expect(watchPartyPlayerStatus(state), 'PARTY 23456789 • $label');
        final visible = watchPartyPlayerStatus(state, localizations: locale)!;
        expect(visible, contains('23456789'));
        expect(visible, contains(locale.text(label)));
        expect(visible, isNot(contains(session.token)));
      }
      final reconnecting = watchPartyPlayerStatus(
        WatchPartyState(
          session: session.withRole(WatchPartyRole.host),
          connection: WatchPartyConnection.reconnecting,
        ),
        localizations: locale,
      );
      expect(reconnecting, contains(locale.text('HOST')));
      expect(reconnecting, contains(locale.text('RECONNECTING')));
      expect(
        watchPartyPlayerStatus(const WatchPartyState(), localizations: locale),
        isNull,
      );
    });
    for (final engine in ['mpv', 'media3']) {
      testWidgets(
        '$engine controls localize in $language without changing control identity',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final playFocus = FocusNode();
          addTearDown(playFocus.dispose);
          var playCount = 0;
          await tester.pumpWidget(
            _localizedApp(
              language,
              TetoPlayerChrome(
                engineKey: engine,
                engineLabel: engine == 'mpv' ? 'MPV' : 'Media3 (Built in)',
                title: 'A title from the provider 日本語',
                streamLabel: 'Provider original label',
                position: const Duration(minutes: 3),
                duration: const Duration(minutes: 24),
                isPlaying: true,
                playFocusNode: playFocus,
                seekBackSeconds: 10,
                seekForwardSeconds: 30,
                onSeek: (_) {},
                onRewind: () {},
                onPlayPause: () => playCount++,
                onForward: () {},
                onPreviousEpisode: () {},
                onNextEpisode: () {},
                onAudio: () {},
                onSubtitles: () {},
                onPicture: () {},
                onPlaybackSpeed: () {},
                onSources: () {},
                onWatchTogether: () {},
                onOptions: () {},
                onDismiss: () {},
              ),
            ),
          );
          await tester.pump();
          final translations = TetoLocalizations(
            AppLanguage.fromCode(language),
          );
          for (final label in [
            'Previous Episode',
            'Pause',
            'Next Episode',
            'Playback Speed',
            'Audio',
            'CC',
            'Picture',
            'Sources',
            'Watch Party',
            'Options',
          ]) {
            expect(find.byTooltip(translations.text(label)), findsOneWidget);
            expect(
              find.byKey(ValueKey('player-control-$label')),
              findsOneWidget,
            );
          }
          expect(
            find.byTooltip(translations.text('Back {value1}s', {'value1': 10})),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('player-control-Back 10s')),
            findsOneWidget,
          );
          expect(find.text('A title from the provider 日本語'), findsOneWidget);
          expect(find.text('Provider original label'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('player-control-Pause')));
          await tester.pump();
          expect(playCount, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('caption size dialog translates options in $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      double? selected;
      await tester.pumpWidget(
        _localizedApp(
          language,
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showPlayerCaptionSizePicker(
                  context: context,
                  current: 34,
                );
              },
              child: const Text('open test'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open test'));
      await tester.pumpAndSettle();
      final translations = TetoLocalizations(AppLanguage.fromCode(language));
      expect(
        find.text(translations.text('Choose caption size')),
        findsOneWidget,
      );
      expect(find.text(translations.text('Extra large')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-track-option-0')));
      await tester.pumpAndSettle();
      expect(selected, 28);
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _localizedApp(String code, Widget body) => MaterialApp(
  locale: Locale(code),
  supportedLocales: TetoLocalizations.supportedLocales,
  localizationsDelegates: const [
    TetoLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(body: body),
);
