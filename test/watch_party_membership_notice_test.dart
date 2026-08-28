import 'package:anime_tv/app/app.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/player/presentation/watch_party_membership_notice.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'app-wide overlay shows every participant action as a safe top-right queue',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _NoticeController()
        ..show(const [
          WatchPartyNotice(
            sequence: 1,
            eventType: WatchPartyEventType.joined,
            displayName: 'Alice',
            actionText: 'joined the party',
            avatarUrl:
                'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b1.jpg',
            message: 'Alice joined the Watch Party.',
          ),
          WatchPartyNotice(
            sequence: 2,
            eventType: WatchPartyEventType.left,
            displayName: 'Bob',
            actionText: 'left the party',
            message: 'Bob left the Watch Party.',
          ),
          WatchPartyNotice(
            sequence: 3,
            eventType: WatchPartyEventType.kicked,
            displayName: 'Carol',
            actionText: 'was kicked from the party',
            message: 'Carol was removed from the Watch Party.',
          ),
          WatchPartyNotice(
            sequence: 4,
            eventType: WatchPartyEventType.hostTransferred,
            displayName: 'Dana',
            actionText: 'is now the host',
            message: 'Host controls transferred to Dana.',
          ),
        ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            watchPartyControllerProvider.overrideWith((_) => controller),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const MediaQuery(
              data: MediaQueryData(
                size: Size(1280, 720),
                padding: EdgeInsets.only(top: 28, right: 34),
              ),
              child: TetoTvGlobalOverlay(
                child: ColoredBox(
                  key: ValueKey('home-route-content'),
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('home-route-content')), findsOneWidget);
      expect(find.byType(WatchPartyMembershipNoticeOverlay), findsOneWidget);
      expect(find.text('joined the party'), findsOneWidget);
      expect(find.text('left the party'), findsOneWidget);
      expect(find.text('was kicked from the party'), findsOneWidget);
      expect(find.text('is now the host'), findsOneWidget);

      final listFinder = find.byKey(
        const ValueKey('watch-party-membership-notice-list'),
      );
      final ignorePointer = tester.widget<IgnorePointer>(
        find
            .ancestor(of: listFinder, matching: find.byType(IgnorePointer))
            .first,
      );
      expect(ignorePointer.ignoring, isTrue);

      final cards = <Rect>[
        for (var sequence = 1; sequence <= 4; sequence++)
          tester.getRect(
            find.byKey(ValueKey('watch-party-membership-notice-$sequence')),
          ),
      ];
      expect(cards.first.top, greaterThanOrEqualTo(28));
      expect(cards.first.width, lessThanOrEqualTo(340));
      for (final card in cards) {
        expect(card.right, lessThanOrEqualTo(1280 - 34));
        expect(card.right, closeTo(cards.first.right, .01));
      }
      for (var index = 0; index < cards.length - 1; index++) {
        expect(
          cards[index].bottom,
          lessThanOrEqualTo(cards[index + 1].top),
          reason: 'simultaneous activity cards must never overlap',
        );
      }

      final emphasizedName = tester.widget<Text>(
        find.byKey(const ValueKey('watch-party-membership-name-1')),
      );
      expect(emphasizedName.style?.fontWeight, FontWeight.w900);
      expect(emphasizedName.style?.color, Colors.white);
      expect(emphasizedName.style?.decoration, TextDecoration.none);
      for (var sequence = 1; sequence <= 4; sequence++) {
        final action = tester.widget<Text>(
          find.byKey(ValueKey('watch-party-membership-action-$sequence')),
        );
        expect(action.style?.color, Colors.white);
        expect(action.style?.decoration, TextDecoration.none);
      }
      final liveRegion = tester.widget<Semantics>(
        find.byKey(const ValueKey('watch-party-membership-notice-1')),
      );
      expect(liveRegion.properties.liveRegion, isTrue);
      expect(liveRegion.excludeSemantics, isTrue);
      expect(liveRegion.properties.label, 'Alice joined the Watch Party.');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('watch-party-membership-avatar-1')),
          matching: find.byType(NetworkArtwork),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('watch-party-membership-avatar-2')),
          matching: find.byType(ClipOval),
        ),
        findsOneWidget,
      );

      final decoration = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('watch-party-membership-name-1')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final box = decoration.decoration as BoxDecoration;
      expect(box.color, const Color(0xF20B0B10));
      expect((box.border! as Border).top.width, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a large activity burst remains inside the TV safe area', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _NoticeController()
      ..show([
        for (
          var sequence = 1;
          sequence <= maximumWatchPartyEventCount;
          sequence++
        )
          WatchPartyNotice(
            sequence: sequence,
            eventType: WatchPartyEventType.joined,
            displayName: 'Viewer $sequence',
            actionText: 'joined the party',
            message: 'Viewer $sequence joined the Watch Party.',
          ),
      ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          watchPartyControllerProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(640, 360),
              textScaler: TextScaler.linear(3),
            ),
            child: TetoTvGlobalOverlay(child: ColoredBox(color: Colors.black)),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('watch-party-membership-notice-1')),
      findsNothing,
    );
    final visibleCards = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'watch-party-membership-notice-',
          ),
    );
    expect(visibleCards, findsNWidgets(5));
    expect(tester.getRect(visibleCards.last).bottom, lessThanOrEqualTo(342));
    expect(
      tester
          .widget<MediaQuery>(
            find
                .ancestor(
                  of: find.byKey(
                    const ValueKey('watch-party-membership-notice-list'),
                  ),
                  matching: find.byType(MediaQuery),
                )
                .first,
          )
          .data
          .textScaler
          .scale(1),
      1.35,
    );
    expect(tester.takeException(), isNull);
  });
}

class _NoticeController extends WatchPartyController {
  _NoticeController()
    : super(WatchPartyClient(baseUrl: 'https://tetotv.example', dio: Dio()));

  void show(List<WatchPartyNotice> notices) {
    state = WatchPartyState(
      notices: List<WatchPartyNotice>.unmodifiable(notices),
    );
  }
}
