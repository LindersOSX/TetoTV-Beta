import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MPV route owns one anonymous streaming presence lease', () {
    final source = File(
      'lib/features/player/presentation/tv_player_screen.dart',
    ).readAsStringSync();
    final routerClass = source.substring(
      source.indexOf('class _TvPlayerScreenRouterState'),
      source.indexOf('class _MpvTvPlayerScreen'),
    );
    expect(routerClass, contains('beginStreaming(_anonymousUsageOwner)'));
    expect(routerClass, contains('endStreaming(_anonymousUsageOwner)'));
    expect(
      routerClass.indexOf('beginStreaming(_anonymousUsageOwner)'),
      lessThan(routerClass.indexOf('endStreaming(_anonymousUsageOwner)')),
    );
    final disposeStart = routerClass.indexOf('void dispose()');
    final disposeEnd = routerClass.indexOf(
      'Future<void> _adoptPlaybackStream',
      disposeStart,
    );
    expect(
      routerClass.substring(disposeStart, disposeEnd),
      isNot(contains('ref.read')),
    );
  });
}
