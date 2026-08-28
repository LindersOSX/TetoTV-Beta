import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Discord callback and launcher share the application task', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      manifest,
      contains('android.support.customtabs.action.CustomTabsService'),
    );
    expect(manifest, contains('android:scheme="https"'));
    final authenticationActivity = RegExp(
      r'<activity\s+[^>]*android:name="com\.discord\.socialsdk\.AuthenticationActivity"[^>]*>[\s\S]*?</activity>',
    ).firstMatch(manifest)?.group(0);
    final mainActivity = RegExp(
      r'<activity\s+[^>]*android:name="\.MainActivity"[^>]*>[\s\S]*?</activity>',
    ).firstMatch(manifest)?.group(0);

    expect(
      authenticationActivity,
      isNotNull,
      reason: 'Discord AuthenticationActivity must be declared by the app.',
    );
    expect(mainActivity, isNotNull);
    expect(authenticationActivity, contains('android:exported="true"'));
    expect(authenticationActivity, contains('android:launchMode="singleTask"'));
    expect(
      authenticationActivity,
      isNot(contains('android:taskAffinity')),
      reason:
          'Discord AuthenticationActivity must keep the application affinity '
          'so the external OAuth callback can reuse its pending singleTask.',
    );
    expect(
      mainActivity,
      isNot(contains('android:taskAffinity')),
      reason:
          'The launcher and Discord callback must share the default application '
          'task affinity. A null launcher affinity strands the pending callback '
          'in a second task when Discord returns to the app.',
    );

    final schemes = RegExp(r'android:scheme="([^"]+)"')
        .allMatches(authenticationActivity!)
        .map((match) => match.group(1))
        .toList();
    expect(schemes, const ['discord-1536801401710055474']);
  });
}
