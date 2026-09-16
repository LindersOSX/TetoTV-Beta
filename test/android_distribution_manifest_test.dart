import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('permissions do not imply optional Bluetooth hardware is required', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final bluetoothFeature = RegExp(
      r'<uses-feature\s+[^>]*android:name="android\.hardware\.bluetooth"[^>]*/>',
    ).firstMatch(manifest)?.group(0);

    expect(
      bluetoothFeature,
      isNotNull,
      reason:
          'The legacy BLUETOOTH permission otherwise implies required '
          'Bluetooth hardware during store filtering.',
    );
    expect(bluetoothFeature, contains('android:required="false"'));
  });
}
