import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('launcher icon uses the high-resolution TetoTV branding asset', () {
    final source = File('assets/branding/tetotv_icon.png').readAsBytesSync();
    expect(source.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);

    final data = ByteData.sublistView(Uint8List.fromList(source));
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    expect(width, height);
    expect(width, greaterThanOrEqualTo(1024));

    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('image_path: "assets/branding/tetotv_icon.png"'));
    expect(pubspec, contains('adaptive_icon_background: "#030303"'));
  });

  test('Android launcher keeps adaptive and themed icon layers', () {
    final adaptiveIcon = File(
      'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    ).readAsStringSync();
    expect(adaptiveIcon, contains('<background'));
    expect(adaptiveIcon, contains('<foreground>'));
    expect(adaptiveIcon, contains('<monochrome>'));

    for (final density in <String>[
      'mdpi',
      'hdpi',
      'xhdpi',
      'xxhdpi',
      'xxxhdpi',
    ]) {
      expect(
        File(
          'android/app/src/main/res/mipmap-$density/ic_launcher.png',
        ).lengthSync(),
        greaterThan(1024),
      );
    }
  });

  test('Android TV banner is generated from the wide branding source', () {
    final source = File(
      'assets/branding/tetotv_tv_banner.png',
    ).readAsBytesSync();
    final sourceData = ByteData.sublistView(Uint8List.fromList(source));
    expect(sourceData.getUint32(16), greaterThanOrEqualTo(1280));
    expect(
      sourceData.getUint32(16) / sourceData.getUint32(20),
      closeTo(16 / 9, 0.01),
    );

    final generated = File(
      'android/app/src/main/res/drawable-xhdpi/tv_banner.png',
    ).readAsBytesSync();
    final generatedData = ByteData.sublistView(Uint8List.fromList(generated));
    expect(generatedData.getUint32(16), 320);
    expect(generatedData.getUint32(20), 180);

    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:banner="@drawable/tv_banner"'));
  });
}
