import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/player/presentation/watch_party_membership_notice.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const name = 'Watch Together {name}';
  const events = [
    (
      WatchPartyEventType.joined,
      'joined the party',
      '{name} joined the Watch Party.',
    ),
    (
      WatchPartyEventType.left,
      'left the party',
      '{name} left the Watch Party.',
    ),
    (
      WatchPartyEventType.kicked,
      'was kicked from the party',
      '{name} was removed from the Watch Party.',
    ),
    (
      WatchPartyEventType.hostTransferred,
      'is now the host',
      'Host controls transferred to {name}.',
    ),
  ];

  for (final code in ['en', 'es', 'pt', 'fr', 'hi', 'de']) {
    testWidgets(
      '$code translates participant actions and accessibility without changing names',
      (tester) async {
        final notices = [
          for (final (index, event) in events.indexed)
            WatchPartyNotice(
              sequence: index + 1,
              eventType: event.$1,
              displayName: name,
              actionText: event.$2,
              message: event.$3.replaceFirst('{name}', name),
            ),
        ];
        await _pump(tester, code, notices);
        final ui = TetoLocalizations(AppLanguage.fromCode(code));
        for (final (index, event) in events.indexed) {
          final sequence = index + 1;
          expect(
            tester
                .widget<Text>(
                  find.byKey(ValueKey('watch-party-membership-name-$sequence')),
                )
                .data,
            name,
          );
          expect(
            tester
                .widget<Text>(
                  find.byKey(
                    ValueKey('watch-party-membership-action-$sequence'),
                  ),
                )
                .data,
            ui.text(event.$2),
          );
          final label = tester
              .widget<Semantics>(
                find.byKey(ValueKey('watch-party-membership-notice-$sequence')),
              )
              .properties
              .label;
          expect(label, ui.text(event.$3, {'name': name}));
          expect(label, contains(name));
          if (code != 'en') expect(label, isNot(notices[index].message));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('synthetic You is localized but a participant named You is not', (
    tester,
  ) async {
    await _pump(tester, 'es', const [
      WatchPartyNotice(
        sequence: 1,
        eventType: WatchPartyEventType.kicked,
        displayName: 'You',
        actionText: 'were kicked from the party',
        message: 'The host removed you from this Watch Party.',
      ),
      WatchPartyNotice(
        sequence: 2,
        eventType: WatchPartyEventType.kicked,
        displayName: 'You',
        actionText: 'was kicked from the party',
        message: 'You was removed from the Watch Party.',
      ),
    ]);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('watch-party-membership-name-1')),
          )
          .data,
      'Tú',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('watch-party-membership-name-2')),
          )
          .data,
      'You',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('watch-party-membership-action-1')),
          )
          .data,
      'fuiste expulsado de la sala',
    );
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('watch-party-membership-notice-1')),
          )
          .properties
          .label,
      'El anfitrión te eliminó de esta Watch Party.',
    );
  });

  testWidgets('system notices localize while unknown text remains intact', (
    tester,
  ) async {
    const fallback =
        'The host’s exact stream is not available here. Using another local source.';
    const custom = 'Custom text {name}: Anime;Title';
    await _pump(tester, 'de', const [
      WatchPartyNotice(sequence: 1, message: fallback),
      WatchPartyNotice(sequence: 2, message: custom),
    ]);
    final ui = TetoLocalizations(AppLanguage.fromCode('de'));
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('watch-party-membership-message-1')),
          )
          .data,
      ui.text(fallback),
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('watch-party-membership-message-2')),
          )
          .data,
      custom,
    );
  });
}

Future<void> _pump(
  WidgetTester tester,
  String code,
  List<WatchPartyNotice> notices,
) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = _Notices(notices);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [watchPartyControllerProvider.overrideWith((_) => controller)],
      child: MaterialApp(
        theme: AppTheme.dark,
        locale: Locale(code),
        supportedLocales: TetoLocalizations.supportedLocales,
        localizationsDelegates: const [
          TetoLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(body: WatchPartyMembershipNoticeOverlay()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Notices extends WatchPartyController {
  _Notices(List<WatchPartyNotice> notices)
    : super(WatchPartyClient(baseUrl: 'https://tetotv.example', dio: Dio())) {
    state = WatchPartyState(notices: List.unmodifiable(notices));
  }
}
