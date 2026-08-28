import 'package:anime_tv/core/legal/bundled_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registers native and bundled JavaScript notices', () async {
    registerBundledThirdPartyLicenses();

    final entries = await LicenseRegistry.licenses.toList();
    final byPackage = <String, String>{};
    for (final entry in entries) {
      final text = entry.paragraphs
          .map((paragraph) => paragraph.text)
          .join('\n');
      for (final package in entry.packages) {
        byPackage[package] = text;
      }
    }

    expect(
      byPackage['Android JS Runtimes bridge 0.3.6'],
      contains('Copyright (c) 2020 fast-development'),
    );
    expect(
      byPackage['QuickJS 2026-06-04'],
      contains('Copyright (c) 2017-2021 Fabrice Bellard'),
    );
    final javascriptNotices =
        byPackage['Bundled add-on JavaScript runtime packages'];
    expect(javascriptNotices, contains('Package: linkedom 0.18.12'));
    expect(javascriptNotices, contains('Package: sucrase 3.35.0'));
    expect(javascriptNotices, contains('Package: boolbase 1.0.0'));
    expect(byPackage['Noto Sans Regular'], contains('SIL OPEN FONT LICENSE'));
    expect(
      byPackage['Noto Sans Regular'],
      contains('Copyright 2018 The Noto Project Authors'),
    );
    expect(
      byPackage['libtorrent4j 2.1.0-38'],
      contains('Copyright (c) 2018-2025 Alden Torres'),
    );
    expect(
      byPackage['libtorrent-rasterbar a01469c'],
      contains('Copyright (c) 2003-2020, Arvid Norberg'),
    );
    expect(
      byPackage['Boost 1.89.0'],
      contains('Boost Software License - Version 1.0'),
    );
    expect(byPackage['OpenSSL 3.5.2'], contains('Apache License'));
    expect(
      byPackage['libdatachannel 6ab310b'],
      contains('Mozilla Public License Version 2.0'),
    );
    expect(
      byPackage['libjuice 2de3524'],
      contains('Mozilla Public License Version 2.0'),
    );
    expect(byPackage['usrsctp ebb18ad'], contains('Copyright (c) 2015'));
    expect(byPackage['libsrtp a566a9c'], contains('Copyright (c) 2001-2017'));
    expect(byPackage['plog e21baec'], contains('MIT License'));
    expect(
      byPackage['Direct torrent native component provenance'],
      contains('libdatachannel commit 6ab310b'),
    );
  });
}
